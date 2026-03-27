# Z.AI Orchestration Guide

## 🎯 Концепция

Использование Claude Code как главного оркестратора с Z.AI в качестве специализированного помощника для выполнения конкретных задач.

## 🚀 Быстрый старт

### Прямой вызов Z.AI

```bash
# Простой запрос
source /root/.bashrc && zai "Your question here" --print

# Анализ файла
source /root/.bashrc && zai "Analyze this file: $(cat lib/phoenix_kit/emails.ex)" --print
```

### Использование скриптов-помощников

#### 1. `zai_helper.sh` - базовые операции

```bash
# Анализ контекста проекта
./scripts/zai_helper.sh context

# Генерация commit message
git add -A
./scripts/zai_helper.sh commit

# Проверка качества кода
./scripts/zai_helper.sh quality lib/phoenix_kit/emails/metrics.ex

# Поиск и исправление ошибок
./scripts/zai_helper.sh fix

# Генерация документации
./scripts/zai_helper.sh docs lib/phoenix_kit/users/auth.ex
```

#### 2. `zai_workflow.sh` - комплексная автоматизация

```bash
# Планирование новой функции
./scripts/zai_workflow.sh plan "email templates with variables"

# Генерация кода
./scripts/zai_workflow.sh generate "rate limiter for API endpoints"

# Полный цикл разработки функции
./scripts/zai_workflow.sh develop "user preferences system"

# Интеллектуальный commit с автоматической генерацией сообщения
./scripts/zai_workflow.sh commit
```

## 📋 Практические примеры использования

### Пример 1: Исправление найденных ошибок

```bash
# 1. Z.AI находит ошибки в коде
./scripts/zai_helper.sh quality lib/phoenix_kit/emails/metrics.ex

# 2. Claude Code применяет исправления
# (вы выполняете исправления на основе рекомендаций Z.AI)

# 3. Z.AI генерирует commit message
./scripts/zai_helper.sh commit
```

### Пример 2: Разработка новой функции

```bash
# 1. Claude Code определяет требования
# 2. Z.AI планирует реализацию
./scripts/zai_workflow.sh plan "email scheduling system"

# 3. Z.AI генерирует код
./scripts/zai_workflow.sh generate "scheduled email sender with Oban"

# 4. Claude Code интегрирует код в проект
# 5. Z.AI проверяет качество
./scripts/zai_workflow.sh review

# 6. Z.AI генерирует тесты
./scripts/zai_workflow.sh test /tmp/generated_code.ex
```

### Пример 3: Комплексный рабочий процесс

```bash
# Полный цикл с одной командой
./scripts/zai_workflow.sh develop "email bounce handling"

# Это автоматически выполнит:
# - Анализ текущего проекта
# - Планирование изменений
# - Генерацию кода
# - Проверку качества
# - Создание тестов
```

## 🏗️ Архитектура взаимодействия

```
┌─────────────────┐
│  Claude Code    │ ← Главный оркестратор
│   (Вы здесь)    │
└────────┬────────┘
         │
         ├─→ Прямые вызовы Z.AI через bash
         │
         ├─→ zai_helper.sh (простые задачи)
         │
         └─→ zai_workflow.sh (комплексные процессы)
```

## 💡 Лучшие практики

1. **Разделение задач**:
   - Claude Code: навигация, интеграция, применение изменений
   - Z.AI: анализ, генерация, проверка качества

2. **Оптимизация промптов**:
   - Давайте Z.AI конкретный контекст (файлы, git diff)
   - Запрашивайте конкретные действия, а не общие советы

3. **Итеративный процесс**:
   - Начинайте с анализа контекста
   - Генерируйте решения поэтапно
   - Всегда проверяйте качество перед коммитом

## 🔧 Настройка моделей

В `.bashrc` настроены функции для разных моделей:

- `zai` - Z.AI с моделью GLM-4.6
- `kimi` - Kimi K2 (Moonshot AI)
- `claude` - стандартный Claude CLI

Можно переключаться между моделями для разных задач:

```bash
# Использовать Kimi для творческих задач
kimi "Generate creative email subject lines" --print

# Использовать Z.AI для технического анализа
zai "Review this code for performance issues" --print
```

## ⚠️ Известные ограничения

1. Ответы Z.AI могут занимать 10-30 секунд
2. Размер контекста ограничен
3. При больших файлах лучше передавать только релевантные части

## 🎉 Результат

С этой системой оркестрации вы получаете:
- **Автоматизацию** рутинных задач
- **Качество** кода через автоматические проверки
- **Скорость** разработки через генерацию кода
- **Консистентность** через следование паттернам проекта