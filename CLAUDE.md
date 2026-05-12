# openwrt-skill — проект разработки project-scoped скилла

Эта папка — **разработка** Claude-скилла для управления OpenWRT-роутерами.
Сам скилл живёт в `.claude/skills/openwrt/` и автоматически активируется только
при работе в этой директории (не глобальный).

## Структура

```
.
├── PROPOSAL.md                  # архитектурный документ (исходное предложение)
├── README.md                    # описание скилла для пользователей
├── CLAUDE.md                    # этот файл — гайд по работе с репо
└── .claude/skills/openwrt/      # ← сам скилл
    ├── SKILL.md                 # entry point — инструкции для агента
    ├── bin/                     # safe API: атомарные операции (агент вызывает ТОЛЬКО отсюда)
    ├── lib/                     # утилиты, source'ятся скриптами (НЕ для агента)
    ├── memory/                  # per-router state (routers.yaml + <alias>/*.md)
    ├── runbooks/                # пошаговые гайды под каждый сценарий
    ├── templates/               # шаблоны конфигов sing-box, watchdog, etc
    ├── schemas/                 # JSON-схемы для валидации
    ├── openwrt/                 # файлы, которые ставятся НА роутер (init.d, etc)
    └── tests/                   # qemu-docker e2e + smoke тесты
```

## Как редактировать скилл

- **Логика операций** → `.claude/skills/openwrt/bin/<op>.sh`. Каждый bin-скрипт
  атомарный: snapshot → валидация → staged-apply → memory update.
- **Общие хелперы** → `.claude/skills/openwrt/lib/`. Контракт — не ломать сигнатуры.
- **Инструкции для агента** → `.claude/skills/openwrt/SKILL.md` и
  `.claude/skills/openwrt/runbooks/`.
- **Per-router state** → `.claude/skills/openwrt/memory/<alias>/*.md`. Обновляется
  автоматически скриптами через `lib/notes-write.sh` / `lib/journal-append.sh`.

Скрипты находят `SKILL_HOME` через `$(dirname $BASH_SOURCE[0])/..` — перемещение
папки скилла не требует правок путей.

## Тесты

```bash
cd .claude/skills/openwrt/tests/qemu-docker
./run-e2e.sh   # требует Docker + ~/.openwrt-skill/secrets/qemu-test.url
```

## Ручной запуск скрипта

```bash
cd .claude/skills/openwrt
bin/doctor.sh --router <alias>
# SKILL_HOME резолвится автоматически от расположения скрипта
```

## Project-scoped vs global

Скилл подключается Claude **только когда открыта эта папка** — структура
`.claude/skills/openwrt/SKILL.md` распознаётся автоматически. Глобальной
регистрации в `~/.claude/skills/` нет и не нужно: для точечной работы с
конкретным набором роутеров достаточно открыть этот проект.
