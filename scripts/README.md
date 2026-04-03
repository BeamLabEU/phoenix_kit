# Claude Code Agent Runner

Бесшовный запуск агентов с визуальным отображением в tmux и автоматическим возвратом результата.

## Быстрый старт

```bash
# Запустить агента - видишь процесс в tmux, результат возвращается автоматически
./scripts/agent.sh "твой промпт"

# С ограничением инструментов
./scripts/agent.sh "анализ кода" --tools "Read,Grep,Glob"

# В новом окне tmux
./scripts/agent.sh "долгая задача" --new-window
```

## Доступные скрипты

| Скрипт | Назначение | Визуал | Результат |
|--------|------------|--------|-----------|
| `agent.sh` | **Рекомендуемый** - бесшовный | ✅ | ✅ Автоматически |
| `run_agent.sh` | Только визуал | ✅ | ❌ Вручную |
| `run_agent_with_output.sh` | Визуал + файл | ✅ | 📁 Файл |
| `run_sdk_agent.py` | Python версия | ✅ | ✅ |

---

## Рекомендации по агентам

### 🚀 Рекомендуется запускать через `agent.sh`

Эти агенты выполняют долгие задачи с большим выводом — удобно видеть прогресс:

#### Feature Development (`feature-dev`)

```bash
# Исследование кодовой базы
./scripts/agent.sh "Проанализируй как работает аутентификация в проекте" \
  --tools "Read,Grep,Glob,Bash"

# Архитектура новой фичи
./scripts/agent.sh "Спроектируй архитектуру модуля биллинга" \
  --tools "Read,Grep,Glob,Bash"
```

| Агент | Описание | Когда использовать |
|-------|----------|-------------------|
| `code-explorer` | Глубокий анализ существующих фич | Изучение кодовой базы |
| `code-architect` | Проектирование архитектуры | Планирование новых фич |
| `code-reviewer` | Ревью кода на баги и качество | После написания кода |

#### PR Review Toolkit (`pr-review-toolkit`)

```bash
# Полный ревью PR
./scripts/agent.sh "Сделай полный code review изменений в git diff" \
  --tools "Read,Grep,Glob,Bash"

# Анализ тестового покрытия
./scripts/agent.sh "Проверь достаточность тестов для PR" \
  --tools "Read,Grep,Glob,Bash"

# Поиск silent failures
./scripts/agent.sh "Найди места где ошибки могут быть проигнорированы" \
  --tools "Read,Grep,Glob"
```

| Агент | Описание | Когда использовать |
|-------|----------|-------------------|
| `code-reviewer` | Полный code review | Перед созданием PR |
| `pr-test-analyzer` | Анализ тестового покрытия | После добавления тестов |
| `silent-failure-hunter` | Поиск скрытых ошибок | При работе с error handling |
| `code-simplifier` | Упрощение кода | После реализации фичи |
| `comment-analyzer` | Проверка комментариев | После документирования |
| `type-design-analyzer` | Анализ типов | При создании новых типов |

#### PhoenixKit Specific

```bash
# Создание компонента
./scripts/agent.sh "Создай компонент для отображения статистики пользователей" \
  --tools "Read,Grep,Glob,Write,Edit"

# Ревью шаблонов
./scripts/agent.sh "Проверь все .heex файлы на соответствие стандартам PhoenixKit" \
  --tools "Read,Grep,Glob"
```

| Агент | Описание | Когда использовать |
|-------|----------|-------------------|
| `phoenix-kit-component-architect` | Компоненты PhoenixKit | Создание/ревью UI компонентов |

#### Plugin Development (`plugin-dev`)

```bash
# Валидация плагина
./scripts/agent.sh "Проверь структуру плагина в .claude/plugins/my-plugin" \
  --tools "Read,Grep,Glob,Bash"
```

| Агент | Описание | Когда использовать |
|-------|----------|-------------------|
| `plugin-validator` | Валидация структуры плагина | После создания плагина |
| `skill-reviewer` | Ревью качества skill | После создания skill |
| `agent-creator` | Создание новых агентов | При добавлении агентов |

---

### ⚡ Лучше запускать напрямую (без визуала)

Эти задачи быстрые и не требуют визуального мониторинга:

```bash
# Быстрые запросы - используй claude -p напрямую
claude -p "Какая версия в mix.exs?" --allowedTools "Read,Grep"

# Или через Task tool внутри Claude Code
# (автоматически выбирает подходящий subagent)
```

---

## Параллельный запуск

```bash
# Два агента одновременно
./scripts/agent.sh "Проверь безопасность кода" --tools "Read,Grep" &
./scripts/agent.sh "Проанализируй тесты" --tools "Read,Grep,Bash" &
wait

# Результаты обоих вернутся после завершения
```

---

## Опции

```bash
./scripts/agent.sh "промпт" [опции]

Опции:
  --tools TOOLS      Разрешённые инструменты (default: Read,Grep,Glob,Bash)
  --new-window       Создать новое окно tmux
  --timeout SECS     Таймаут в секундах (default: 300)
  --session NAME     Имя tmux сессии (default: phoenixkit)
```

---

## Примеры использования

### Git-анализ

```bash
# Кто изменял файл
./scripts/agent.sh "Кто и когда изменял lib/phoenix_kit/users/auth.ex? Покажи историю." \
  --tools "Bash,Read"

# Анализ между версиями
./scripts/agent.sh "Что изменилось между v1.6.0 и v1.7.0?" \
  --tools "Bash,Read,Grep"
```

### Рефакторинг

```bash
# Найти дублирование
./scripts/agent.sh "Найди дублирующийся код в lib/phoenix_kit_web/live/" \
  --tools "Read,Grep,Glob"

# Предложить улучшения
./scripts/agent.sh "Проанализируй lib/phoenix_kit/emails/ и предложи улучшения архитектуры" \
  --tools "Read,Grep,Glob"
```

### Документация

```bash
# Сгенерировать документацию
./scripts/agent.sh "Создай документацию для модуля PhoenixKit.Users.Auth" \
  --tools "Read,Grep"
```

---

## Архитектура

```
┌─────────────────────────────────────────────────────┐
│  Вызывающий (Claude Code / скрипт)                  │
│                                                     │
│  agent.sh "prompt" ────┬──────────────────────────► │
│         ▲              │                            │
│         │              ▼                            │
│    Результат    ┌─────────────┐                     │
│    (stdout)     │ tmux pane   │ ◄── Пользователь    │
│         ▲       │ (визуально) │     видит прогресс  │
│         │       └──────┬──────┘                     │
│         │              │                            │
│         │              ▼                            │
│         │       ┌─────────────┐                     │
│         └───────│ temp file   │                     │
│                 │ (результат) │                     │
│                 └─────────────┘                     │
└─────────────────────────────────────────────────────┘
```

---

## Полный список агентов

### Глобальные (`~/.claude/agents/`)

- `phoenix-kit-component-architect` - UI компоненты PhoenixKit

### Проектные (`/app/.claude/agents/`)

- `phoenix-kit-component-architect` - UI компоненты PhoenixKit

### Из плагинов

#### feature-dev
- `code-explorer` - исследование кода
- `code-architect` - архитектура фич
- `code-reviewer` - code review

#### pr-review-toolkit
- `code-reviewer` - ревью PR (модель opus)
- `code-simplifier` - упрощение кода
- `comment-analyzer` - анализ комментариев
- `pr-test-analyzer` - анализ тестов
- `silent-failure-hunter` - поиск скрытых ошибок
- `type-design-analyzer` - анализ типов

#### plugin-dev
- `plugin-validator` - валидация плагинов
- `skill-reviewer` - ревью skills
- `agent-creator` - создание агентов

#### agent-sdk-dev
- `agent-sdk-verifier-py` - верификация Python SDK
- `agent-sdk-verifier-ts` - верификация TypeScript SDK
