#!/bin/bash

# Z.AI Workflow Orchestrator - полная автоматизация рабочего процесса
# Этот скрипт использует Z.AI для выполнения сложных многоэтапных задач

source /root/.bashrc 2>/dev/null

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Функция логирования
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

# 1. Анализ и планирование изменений
plan_changes() {
    local feature=$1
    log "${BLUE}📋 Планирование изменений для: $feature${NC}"

    local plan_prompt="Create a detailed implementation plan for adding '$feature' to PhoenixKit.
    Include:
    1. Files that need to be modified
    2. New files that need to be created
    3. Database migrations required
    4. Tests that should be written
    5. Potential risks and how to mitigate them
    Be specific with file paths and module names."

    zai "$plan_prompt" --print > /tmp/implementation_plan.txt
    echo -e "${GREEN}План сохранён в /tmp/implementation_plan.txt${NC}"
}

# 2. Генерация кода на основе плана
generate_code() {
    local requirement=$1
    log "${BLUE}⚙️ Генерация кода для: $requirement${NC}"

    local code_prompt="Generate production-ready Elixir/Phoenix code for: $requirement
    Follow PhoenixKit conventions:
    - Use library-first architecture
    - Include proper error handling
    - Add @moduledoc and @doc documentation
    - Follow Elixir style guide
    Provide complete, working code."

    zai "$code_prompt" --print > /tmp/generated_code.ex
    echo -e "${GREEN}Код сохранён в /tmp/generated_code.ex${NC}"
}

# 3. Проверка и исправление кода перед коммитом
review_and_fix() {
    log "${BLUE}🔍 Проверка всех изменений...${NC}"

    # Собираем все изменённые файлы
    local changed_files=$(git diff --name-only)

    if [ -z "$changed_files" ]; then
        echo -e "${YELLOW}Нет изменений для проверки${NC}"
        return
    fi

    for file in $changed_files; do
        if [[ $file == *.ex ]] || [[ $file == *.exs ]]; then
            log "Проверяю: $file"

            local file_content=$(cat "$file")
            local review_prompt="Review this Elixir code for issues:
            File: $file

            $file_content

            Check for:
            - Syntax errors
            - Logic bugs
            - Security issues
            - Performance problems
            - Missing error handling

            If you find issues, provide exact fixes with line numbers."

            zai "$review_prompt" --print > "/tmp/review_${file##*/}.txt"
            echo -e "${GREEN}Результат проверки: /tmp/review_${file##*/}.txt${NC}"
        fi
    done
}

# 4. Генерация тестов
generate_tests() {
    local module_file=$1
    log "${BLUE}🧪 Генерация тестов для: $module_file${NC}"

    if [ ! -f "$module_file" ]; then
        echo -e "${RED}Файл не найден: $module_file${NC}"
        return
    fi

    local module_content=$(cat "$module_file")

    local test_prompt="Generate comprehensive ExUnit tests for this Elixir module:

    $module_content

    Include:
    - Unit tests for each public function
    - Edge case tests
    - Error handling tests
    - Integration tests if applicable
    Use PhoenixKit test conventions and DataCase where appropriate."

    zai "$test_prompt" --print > "/tmp/test_${module_file##*/}"
    echo -e "${GREEN}Тесты сохранены в /tmp/test_${module_file##*/}${NC}"
}

# 5. Полный цикл разработки фичи
develop_feature() {
    local feature_name=$1

    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}🚀 Полный цикл разработки: $feature_name${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Этап 1: Анализ текущего состояния
    log "${BLUE}Этап 1: Анализ проекта${NC}"
    local analysis_prompt="Analyze PhoenixKit at /app to understand how to implement '$feature_name'.
    Check existing patterns, dependencies, and integration points."

    zai "$analysis_prompt" --print > /tmp/analysis.txt
    echo -e "${GREEN}Анализ завершён${NC}"

    # Этап 2: Планирование
    log "${BLUE}Этап 2: Планирование${NC}"
    plan_changes "$feature_name"

    # Этап 3: Генерация кода
    log "${BLUE}Этап 3: Генерация кода${NC}"
    generate_code "$feature_name"

    # Этап 4: Проверка качества
    log "${BLUE}Этап 4: Проверка качества${NC}"
    mix format
    review_and_fix

    # Этап 5: Генерация тестов
    log "${BLUE}Этап 5: Генерация тестов${NC}"
    if [ -f "/tmp/generated_code.ex" ]; then
        generate_tests "/tmp/generated_code.ex"
    fi

    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✅ Разработка завершена!${NC}"
    echo ""
    echo "Результаты сохранены в /tmp/:"
    echo "  - analysis.txt         - анализ проекта"
    echo "  - implementation_plan.txt - план реализации"
    echo "  - generated_code.ex    - сгенерированный код"
    echo "  - test_generated_code.ex - тесты"
    echo "  - review_*.txt         - результаты проверки"
}

# 6. Интеллектуальный коммит
smart_commit() {
    log "${BLUE}🎯 Интеллектуальный коммит${NC}"

    # Проверяем staged изменения
    local staged_diff=$(git diff --cached)

    if [ -z "$staged_diff" ]; then
        # Если нет staged, добавляем все изменения
        log "Добавляю все изменения..."
        git add -A
        staged_diff=$(git diff --cached)
    fi

    if [ -z "$staged_diff" ]; then
        echo -e "${RED}Нет изменений для коммита${NC}"
        return
    fi

    # Генерируем коммит
    local commit_prompt="Generate a git commit message for these changes:

    $staged_diff

    Rules:
    - Start with: Add, Update, Fix, Remove, or Merge
    - Be specific about what changed
    - Keep under 50 characters
    - Focus on WHY, not just WHAT

    Return ONLY the commit message, nothing else."

    local commit_msg=$(zai "$commit_prompt" --print 2>/dev/null | tail -n 1)

    echo -e "${GREEN}Предлагаемый коммит:${NC}"
    echo "$commit_msg"
    echo ""
    echo -n "Создать коммит? (y/n): "
    read -r response

    if [[ "$response" == "y" ]]; then
        git commit -m "$commit_msg"
        echo -e "${GREEN}✅ Коммит создан!${NC}"

        # Предлагаем push
        echo -n "Отправить в репозиторий? (y/n): "
        read -r push_response
        if [[ "$push_response" == "y" ]]; then
            git push
            echo -e "${GREEN}✅ Изменения отправлены!${NC}"
        fi
    fi
}

# Главное меню
case "$1" in
    plan)
        plan_changes "$2"
        ;;
    generate)
        generate_code "$2"
        ;;
    review)
        review_and_fix
        ;;
    test)
        generate_tests "$2"
        ;;
    develop)
        develop_feature "$2"
        ;;
    commit)
        smart_commit
        ;;
    *)
        echo -e "${PURPLE}Z.AI Workflow Orchestrator${NC}"
        echo "Полная автоматизация разработки с помощью Z.AI"
        echo ""
        echo "Команды:"
        echo "  plan <feature>     - Планирование реализации функции"
        echo "  generate <desc>    - Генерация кода по описанию"
        echo "  review            - Проверка всех изменений"
        echo "  test <file>       - Генерация тестов для модуля"
        echo "  develop <feature> - Полный цикл разработки"
        echo "  commit            - Интеллектуальный git commit"
        echo ""
        echo "Примеры:"
        echo "  $0 plan \"email templates with variables\""
        echo "  $0 generate \"rate limiter for API\""
        echo "  $0 review"
        echo "  $0 test lib/phoenix_kit/emails.ex"
        echo "  $0 develop \"user preferences system\""
        echo "  $0 commit"
        ;;
esac