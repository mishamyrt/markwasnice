# План рефакторинга backend_geodock

## Цели

- Повысить производительность API под concurrent-нагрузкой.
- Уменьшить сайд-эффекты за счёт явных границ транзакций и разделения ответственности.
- Закрыть критичные security gaps.
- Сократить количество DB-сессий и прямых подключений к PostgreSQL в рамках одного request.
- Привести проект к поддерживаемому FastAPI Design Pattern: `router -> dependency -> service -> repository -> db`.

## Критичные проблемы

### 1. Не все роутеры защищены JWT

В `app/main.py` часть роутеров подключена без `dependencies=_jwt_auth`: `condition`, `coord_river`, `coord_grid`, `tpi`, `gold_*`, `loaders`, `draw_info`, `user_interface`, `geotrack/*`, `well`.

Риск: публичный доступ к тяжёлым операциям, загрузкам, S3/Airflow/геообработке и потенциально чувствительным данным.

План:

- Оставить публичными только `/auth/*` и health/default endpoints.
- Все остальные роутеры подключать с JWT dependency по умолчанию.
- Для write/upload/delete/admin операций добавить role-based dependencies.
- Для file storage проверять доступ пользователя к `license_number` через выбранную лицензию/роль.

### 2. Sync I/O и CPU-heavy операции внутри `async def`

Во многих endpoint-ах используются `pandas`, `openpyxl`, `boto3`, `psycopg2`, `rasterio`, `geopandas`, Spark/Airflow polling и тяжёлые DataFrame/геооперации внутри `async def`.

Риск: блокировка event loop, деградация всех concurrent requests, DoS через один тяжёлый запрос.

План:

- Endpoint-ы с синхронным I/O сделать обычными `def`, чтобы FastAPI выполнял их в threadpool.
- Долгие задачи вынести в background worker: Celery/RQ/Arq или Airflow job с polling/status endpoint.
- Для коротких sync-фрагментов в async endpoint использовать `run_in_threadpool`.
- Ввести лимиты: размер файла, bbox area, timeout, concurrency per user/IP.

### 3. Смешаны SQLAlchemy Session и прямой `psycopg2.connect()`

Сейчас auth dependency открывает SQLAlchemy session, а бизнес-логика часто открывает отдельные `psycopg2` connections через `app/db/postgres.py` или утилиты.

Риск: несколько DB connections на один request, отсутствие общего transaction boundary, дорогие TCP-подключения, сложная отладка.

План:

- Выбрать единый способ доступа к PostgreSQL: SQLAlchemy 2.0 engine/session.
- Перенести raw SQL на `Session.execute(text(...))` или repository methods поверх общего engine.
- Убрать прямые `psycopg2.connect()` из request path.
- Передавать `Session` через dependencies на service/repository уровень.
- Для read-only запросов не делать `commit()`.

### 4. Лишние DB-запросы и подключения в `/well`

`/well` сначала проверяет `license_exists()`, затем отдельно вызывает `fetch_wells()`. При включённом auth это минимум SQLAlchemy session для пользователя плюс отдельные PostgreSQL connections для проверки лицензии и выборки скважин.

План:

- Убрать отдельный pre-check или объединить его с выборкой в одном repository method.
- Если нужен 404 для несуществующей лицензии, выполнять check и fetch в одной DB session/connection.
- Добавить лимиты/pagination для больших выборок скважин.

### 5. Небезопасные production defaults

В auth-конфиге есть fallback-значения `JWT_SECRET_KEY=CHANGE-ME-IN-PRODUCTION` и `ADMIN_PASSWORD=changeme`. На старте создаётся default admin.

Риск: запуск production с известным JWT secret/admin password, компрометация аккаунта администратора.

План:

- В production fail-fast при дефолтных/пустых `JWT_SECRET_KEY`, `ADMIN_PASSWORD`, DB/S3 secrets.
- Не пересинхронизировать пароль существующего admin из env.
- Default admin создавать только один раз и с `must_change_password=True`.
- Перенести secrets в secret manager/CI masked variables.

### 6. Refresh tokens хранятся plaintext и ротация не атомарна

`refresh_tokens.token` хранит сам токен. Ротация делает select, затем revoke, затем создание нового токена без row lock.

Риск: утечка refresh-токенов из БД, race condition при параллельном refresh, выпуск нескольких новых токенов.

План:

- Хранить hash refresh token, не plaintext.
- Использовать `secrets.token_urlsafe(32+)`.
- Делать ротацию атомарно: row lock `SELECT ... FOR UPDATE` или conditional update.
- При повторном использовании revoked token отзывать всю token family.

### 7. CORS разрешён для всех origins с credentials

`allow_origins=["*"]` вместе с `allow_credentials=True` небезопасен и плохо контролируется.

План:

- Вынести CORS allowlist в env.
- В production разрешать только конкретные frontend origins.
- Не включать credentials, если авторизация идёт через Bearer token, а не cookies.

### 8. Загрузка файлов целиком в память

Во многих местах используется `await file.read()` / `uploaded_file.read()` и затем Pandas/OpenPyXL/S3 создают дополнительные копии.

Риск: OOM и DoS через большой upload.

План:

- Ввести max upload size на middleware/proxy/API уровне.
- Для S3 использовать streaming upload: `upload_fileobj` или временный файл.
- Excel/CSV parsing выносить в worker/threadpool.
- Для больших файлов возвращать job id, а не держать HTTP request до конца обработки.

### 9. Большие выборки без лимитов и `SELECT *`

Есть endpoints и utils, которые выбирают большие таблицы полностью, материализуют их в DataFrame/JSON и отдают клиенту.

Риск: высокая память, долгие запросы, блокировки CPU, большой network payload.

План:

- Запретить unbounded list endpoints.
- Ввести обязательные фильтры для больших таблиц.
- Добавить pagination/cursor pagination.
- Выбирать только нужные колонки.
- Разделить list DTO и detail/map DTO.
- Геометрию отдавать только там, где она реально нужна.

### 10. Raw exception messages возвращаются клиенту

Некоторые endpoint-ы возвращают `str(e)` наружу.

Риск: утечка SQL, путей, S3/Airflow details, внутренних структур.

План:

- Ввести единый exception handler.
- Клиенту возвращать generic message и `error_id`.
- Подробности писать только в structured logs.

## Целевая структура FastAPI

```text
app/
  main.py
  core/
    config.py
    logging.py
    security.py
    errors.py
  api/
    deps.py
    v1/
      router.py
      auth.py
      wells.py
      licenses.py
      files.py
      geotrack.py
  domain/
    users.py
    licenses.py
    wells.py
    files.py
  schemas/
    auth.py
    wells.py
    licenses.py
  services/
    auth_service.py
    well_service.py
    license_service.py
    file_service.py
    geotrack_service.py
  repositories/
    users.py
    refresh_tokens.py
    wells.py
    licenses.py
    files.py
  db/
    session.py
    models.py
    migrations/
  integrations/
    s3.py
    airflow.py
    geoprocessing.py
  workers/
    tasks.py
```

Правила ответственности:

- `api/*`: только HTTP, validation, dependencies, response models.
- `services/*`: бизнес-операции, orchestration, transaction boundary.
- `repositories/*`: SQL/ORM queries, без HTTPException и без FastAPI imports.
- `integrations/*`: S3, Airflow, внешние API, raster/vector libraries.
- `db/*`: engine/session/models, без бизнес-логики.
- `core/*`: settings, logging, security primitives, exception handling.

## Целевой request flow

```text
Request
  -> router endpoint
  -> dependencies: current_user, role, db session
  -> service method
  -> repository methods через ту же db session
  -> commit/rollback на service/use-case boundary
  -> schema response
```

Для read-only endpoints:

- session открывается один раз на request;
- commit не выполняется;
- repository возвращает domain/data rows;
- service собирает response DTO.

Для write endpoints:

- service управляет транзакцией;
- repositories делают `add/execute/flush`, но не `commit`;
- commit один раз после успешного use-case;
- rollback централизованно при исключении.

## Поэтапный план

### Этап 0. Подготовка и safety net

- Зафиксировать текущие публичные API contracts.
- Добавить smoke tests для auth, `/well`, file storage, license endpoints, geotrack heavy endpoints.
- Добавить тесты на отсутствие публичного доступа без JWT для всех non-health routes.
- Добавить базовый performance baseline: latency, DB connection count, memory for heavy uploads.
- Включить structured logging с request id.

Критерий готовности: можно безопасно менять структуру и видеть regressions.

### Этап 1. Security hardening

- Закрыть JWT все non-public routers.
- Настроить role-based access для mutation/upload/delete/admin actions.
- Ввести production settings validation.
- Исправить default admin behavior.
- Ограничить CORS allowlist.
- Перестать возвращать raw exceptions клиенту.
- Добавить rate limit на login/refresh и тяжёлые endpoints.

Критерий готовности: без JWT доступны только auth и health; production не стартует с дефолтными секретами.

### Этап 2. Единая конфигурация и DI

- Создать `core/config.py` на Pydantic Settings.
- Перенести все env reads из модулей в settings.
- Создать единые dependencies: `get_db`, `get_current_user`, `require_roles`, `get_settings`.
- Убрать `load_dotenv()` из бизнес-модулей.

Критерий готовности: конфиг валидируется при старте, модули не читают env напрямую.

### Этап 3. DB access и сокращение сессий

- Перевести `db/postgres.py`, `db/wells.py`, `utils/geodock/*` с direct `psycopg2.connect()` на общий SQLAlchemy engine/session.
- Разнести SQL по repositories.
- Убрать commits из низкоуровневых helper-функций.
- Убрать read-only commits.
- Объединить check+fetch patterns в один repository call там, где это уменьшает round-trips.
- Настроить pool size, max overflow, pool timeout, connect timeout через settings.

Критерий готовности: один request использует одну DB session для auth и бизнес-логики, кроме явно обоснованных внешних jobs.

### Этап 4. Разделение router/service/repository

- Начать с `/well`, потому что модуль компактный и уже имеет service.
- Затем вынести `license`, `geo_licenses`, `file_storage`.
- Потом вынести `journal`, `condition`, `coord_river`, `geotrack`.
- Убрать FastAPI imports из services/repositories, кроме явных application errors.
- Ввести domain/application exceptions и mapping в HTTP на api layer.

Критерий готовности: router не содержит SQL/S3/Pandas/business logic.

### Этап 5. Производительность heavy endpoints

- Перевести sync-heavy `async def` в `def` или `run_in_threadpool`.
- Вынести долгие операции в background jobs.
- Добавить job status endpoints.
- Ограничить upload size, bbox area, page size.
- Для S3 listing использовать paginator.
- Для file upload/download использовать streaming.
- Для DataFrame/Excel processing использовать временные файлы и worker.

Критерий готовности: тяжёлый запрос не блокирует event loop и не держит всю нагрузку в одном API worker.

### Этап 6. Query optimization и PostGIS

- Убрать `SELECT *` из public paths.
- Ввести list/detail DTO: list без тяжёлой geometry, detail/map с geometry.
- Добавить pagination для всех списков.
- Проверить `EXPLAIN ANALYZE` для bbox/search queries.
- Для PostGIS bbox не применять `ST_Transform(geometry)` в WHERE без functional GiST index.
- Добавить GiST/functional GiST индексы или трансформировать bbox в SRID таблицы.
- Для текстового поиска добавить `pg_trgm`/`tsvector` индексы на реально используемые поля.

Критерий готовности: основные map/search endpoints используют индексы и имеют bounded response size.

### Этап 7. Auth tokens и audit

- Хранить refresh token hash вместо plaintext.
- Сделать atomic rotation.
- Добавить token family/reuse detection.
- Добавить audit log для login, refresh, password change, file delete/upload, admin actions.
- Добавить rate limiting/lockout.

Критерий готовности: компрометация БД не раскрывает active refresh tokens, refresh race невозможен.

### Этап 8. Тесты, observability, rollout

- Добавить unit tests для services/repositories.
- Добавить integration tests с test DB для critical SQL.
- Добавить auth/security tests.
- Добавить load test для `/well`, file upload, geotrack/map endpoints.
- Ввести metrics: latency, DB pool usage, job duration, upload size, error rate.
- Раскатывать по модулям, не переписывать весь проект одним PR.

Критерий готовности: изменения можно включать постепенно и измерять эффект.

## Приоритетный порядок работ

1. Закрыть публичные роутеры JWT и role-based access.
2. Fail-fast production config и убрать небезопасный default admin behavior.
3. Ввести единый settings слой.
4. Унифицировать DB access и убрать прямые `psycopg2.connect()` из request path.
5. Перенести `/well` на чистый `router -> service -> repository` как эталон.
6. Перенести file storage и licenses на тот же pattern.
7. Вынести heavy processing в worker/threadpool и добавить лимиты.
8. Оптимизировать PostGIS/search queries и response DTO.
9. Усилить refresh token model и audit.
10. Покрыть regression/load/security тестами.

## Быстрые wins без большой переписи

- Подключить JWT dependency ко всем non-public routers.
- Вынести CORS origins в env.
- Запретить production start с дефолтными secrets.
- Убрать `commit()` после read-only `SELECT`.
- Добавить `connect_timeout`, `pool_timeout` и env-настройки DB pool.
- В `/well` объединить проверку лицензии и выборку в одном DB access path.
- Ограничить max upload size.
- Добавить S3 paginator для list endpoints.
- Заменить raw `str(e)` в HTTP responses на generic errors.

## Ожидаемый эффект

- Меньше DB connections на request и меньше round-trips.
- Event loop перестаёт блокироваться тяжёлыми sync-операциями.
- Уменьшается риск DoS через upload/bbox/heavy endpoints.
- Production становится безопаснее за счёт обязательных secrets и закрытых роутов.
- Код становится сопровождаемым: HTTP, бизнес-логика, SQL и интеграции разделены.
