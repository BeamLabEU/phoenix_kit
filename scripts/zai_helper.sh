#!/bin/bash

# Z.AI Helper - специализированный помощник для работы с Z.AI
# Используется для оркестрации задач через Z.AI модель

# Загружаем функцию zai
source /root/.bashrc 2>/dev/null

# Цвета для вывода
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Функция вывода заголовка
print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🤖 Z.AI Assistant: $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Функция для сбора контекста проекта
gather_context() {
    print_header "Сбор контекста проекта"

    local analysis_prompt="Analyze the PhoenixKit project at /app. Focus on:
    1. Current module structure in lib/
    2. Recent changes in git log (last 5 commits)
    3. TODO comments in the code
    4. Identify areas that need improvement
    Be specific and actionable."

    echo -e "${YELLOW}Анализирую проект...${NC}"
    zai "$analysis_prompt" --print
}

# Функция для генерации commit message
generate_commit() {
    print_header "Генерация commit message"

    # Получаем git diff
    local git_diff=$(git diff --cached)

    if [ -z "$git_diff" ]; then
        echo -e "${RED}Нет изменений для коммита (git diff --cached пустой)${NC}"
        echo "Сначала добавьте файлы: git add <files>"
        return 1
    fi

    local commit_prompt="Based on the following git diff, generate a commit message following these rules:
    - Start with action verb: Add, Update, Fix, Remove, Merge
    - Be specific about what changed
    - Keep it under 50 characters

    Git diff:
    $git_diff

    Generate ONLY the commit message, nothing else."

    echo -e "${YELLOW}Генерирую commit message...${NC}"
    local commit_msg=$(zai "$commit_prompt" --print 2>/dev/null | tail -n 1)

    echo -e "${GREEN}Предлагаемый commit:${NC}"
    echo "$commit_msg"
    echo ""
    echo -e "${YELLOW}Использовать этот commit? (y/n):${NC}"
    read -r response

    if [[ "$response" == "y" ]]; then
        git commit -m "$commit_msg"
        echo -e "${GREEN}✅ Commit создан!${NC}"
    else
        echo -e "${YELLOW}Commit отменён${NC}"
    fi
}

# Функция проверки качества кода с автоматическим исправлением
quality_check() {
    print_header "Комплексная проверка качества с автоисправлением"

    echo -e "${BLUE}🔍 Запускаю mix quality...${NC}"
    echo ""

    local has_errors=false
    local error_log="/tmp/quality_errors.log"
    > "$error_log"

    # 1. Проверка форматирования
    echo -e "${YELLOW}📝 Этап 1/3: Проверка форматирования (mix format)${NC}"
    if ! mix format --check-formatted 2>&1; then
        echo -e "${YELLOW}⚠️  Найдены проблемы форматирования. Исправляю...${NC}"
        mix format
        echo -e "${GREEN}✅ Форматирование исправлено${NC}"
    else
        echo -e "${GREEN}✅ Форматирование в порядке${NC}"
    fi
    echo ""

    # 2. Статический анализ с Credo
    echo -e "${YELLOW}🔎 Этап 2/3: Статический анализ (mix credo)${NC}"
    local credo_output=$(mix credo --strict --format json 2>/dev/null || echo "{}")
    local credo_issues=$(echo "$credo_output" | grep -o '"message"' | wc -l)

    if [ "$credo_issues" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Найдено проблем Credo: $credo_issues${NC}"
        has_errors=true

        # Сохраняем читаемый вывод Credo
        mix credo --strict 2>&1 | tee -a "$error_log" | head -20
        echo "..." >> "$error_log"
        echo ""

        # Запрашиваем исправления у Z.AI
        echo -e "${BLUE}🤖 Запрашиваю исправления у Z.AI...${NC}"

        local credo_fix_prompt="Fix these Elixir Credo warnings from PhoenixKit:

$(mix credo --strict 2>&1 | head -50)

Provide specific code fixes for each issue. Be concise but complete.
Focus on actual fixes, not explanations."

        local fix_suggestions=$(zai "$credo_fix_prompt" --print 2>/dev/null)
        echo "$fix_suggestions" > /tmp/credo_fixes.txt
        echo -e "${GREEN}💡 Предложения по исправлению сохранены в /tmp/credo_fixes.txt${NC}"
    else
        echo -e "${GREEN}✅ Статический анализ пройден${NC}"
    fi
    echo ""

    # 3. Проверка типов с Dialyzer
    echo -e "${YELLOW}🔬 Этап 3/3: Проверка типов (mix dialyzer)${NC}"
    echo -e "${YELLOW}(может занять время при первом запуске)${NC}"

    local dialyzer_output=$(mix dialyzer 2>&1 || true)

    if echo "$dialyzer_output" | grep -q "done (warnings were emitted)"; then
        echo -e "${YELLOW}⚠️  Найдены предупреждения Dialyzer${NC}"
        has_errors=true

        echo "$dialyzer_output" | grep -A 2 "warning:" | head -20 | tee -a "$error_log"
        echo ""

        # Запрашиваем исправления у Z.AI
        echo -e "${BLUE}🤖 Запрашиваю исправления типов у Z.AI...${NC}"

        local dialyzer_fix_prompt="Fix these Elixir Dialyzer type warnings:

$(echo "$dialyzer_output" | grep -A 2 "warning:" | head -30)

Provide specific @spec and type fixes for each warning.
Include exact code to add or modify."

        local type_fixes=$(zai "$dialyzer_fix_prompt" --print 2>/dev/null)
        echo "$type_fixes" > /tmp/dialyzer_fixes.txt
        echo -e "${GREEN}💡 Исправления типов сохранены в /tmp/dialyzer_fixes.txt${NC}"
    elif echo "$dialyzer_output" | grep -q "done (passed successfully)"; then
        echo -e "${GREEN}✅ Проверка типов пройдена${NC}"
    else
        echo -e "${YELLOW}⏭️  Dialyzer пропущен (возможно, не настроен)${NC}"
    fi
    echo ""

    # 4. Дополнительная проверка конкретного файла, если указан
    local file=$1
    if [ -n "$file" ] && [ -f "$file" ]; then
        echo -e "${BLUE}📄 Дополнительная проверка файла: $file${NC}"

        local file_content=$(cat "$file")
        local file_check_prompt="Review this specific Elixir file for issues not caught by tools:

File: $file
Content:
$file_content

Look for:
- Logic errors
- Performance issues
- Security vulnerabilities
- Missing error handling
- Incorrect business logic

Provide only critical issues with specific fixes."

        echo -e "${YELLOW}Анализирую $file...${NC}"
        local file_review=$(zai "$file_check_prompt" --print 2>/dev/null)
        echo "$file_review" > /tmp/file_review_$(basename "$file").txt
        echo -e "${GREEN}📋 Ревью файла сохранено в /tmp/file_review_$(basename "$file").txt${NC}"
    fi

    # 5. Итоговый отчёт
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}📊 ИТОГОВЫЙ ОТЧЁТ${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ "$has_errors" = true ]; then
        echo -e "${YELLOW}⚠️  Найдены проблемы качества${NC}"
        echo ""
        echo "📁 Результаты проверки сохранены:"
        echo "   - /tmp/quality_errors.log - все ошибки"
        [ -f /tmp/credo_fixes.txt ] && echo "   - /tmp/credo_fixes.txt - исправления Credo"
        [ -f /tmp/dialyzer_fixes.txt ] && echo "   - /tmp/dialyzer_fixes.txt - исправления типов"
        [ -n "$file" ] && [ -f /tmp/file_review_$(basename "$file").txt ] && echo "   - /tmp/file_review_$(basename "$file").txt - ревью файла"
        echo ""
        echo -e "${YELLOW}Хотите применить предложенные исправления? (просмотрите файлы выше)${NC}"
        echo "Для применения исправлений используйте редактор или команду Edit"
    else
        echo -e "${GREEN}✅ Все проверки качества пройдены успешно!${NC}"
        echo "Код соответствует стандартам качества проекта."
    fi
}

# Функция автоматического исправления ошибок
fix_errors() {
    print_header "Автоматическое исправление ошибок"

    echo -e "${YELLOW}Запускаю тесты и проверки...${NC}"

    # Собираем ошибки
    local errors=""

    # Проверка форматирования
    if ! mix format --check-formatted 2>/dev/null; then
        errors="${errors}Formatting issues found\n"
        echo -e "${YELLOW}Исправляю форматирование...${NC}"
        mix format
    fi

    # Проверка компиляции
    local compile_errors=$(mix compile 2>&1 | grep -E "error:|warning:")
    if [ -n "$compile_errors" ]; then
        errors="${errors}Compilation errors:\n$compile_errors\n"
    fi

    # Если есть ошибки, просим Z.AI помочь
    if [ -n "$errors" ]; then
        local fix_prompt="Help fix these Elixir/Phoenix errors:

        $errors

        Provide specific fixes with code examples.
        Explain what needs to be changed and why."

        echo -e "${YELLOW}Найдены ошибки. Запрашиваю решение у Z.AI...${NC}"
        zai "$fix_prompt" --print
    else
        echo -e "${GREEN}✅ Ошибок не найдено!${NC}"
    fi
}

# Функция для создания документации
generate_docs() {
    print_header "Генерация документации"

    local module=$1

    if [ -z "$module" ]; then
        echo -e "${RED}Укажите модуль для документирования${NC}"
        echo "Использование: $0 docs <module_file.ex>"
        return 1
    fi

    local module_content=$(cat "$module" 2>/dev/null)

    if [ -z "$module_content" ]; then
        echo -e "${RED}Не могу прочитать файл: $module${NC}"
        return 1
    fi

    local docs_prompt="Generate comprehensive @moduledoc and @doc documentation for this Elixir module:

    $module_content

    Include:
    - Module purpose and overview
    - Function descriptions with examples
    - Parameter explanations
    - Return value descriptions
    Use proper Elixir ExDoc format."

    echo -e "${YELLOW}Генерирую документацию для $module...${NC}"
    zai "$docs_prompt" --print
}

# Основная логика
case "$1" in
    context)
        gather_context
        ;;
    commit)
        generate_commit
        ;;
    quality)
        quality_check "$2"
        ;;
    fix)
        fix_errors
        ;;
    docs)
        generate_docs "$2"
        ;;
    *)
        echo -e "${GREEN}Z.AI Helper - Оркестратор для работы с Z.AI${NC}"
        echo ""
        echo "Использование: $0 <команда> [параметры]"
        echo ""
        echo "Команды:"
        echo "  context        - Собрать контекст проекта и найти области для улучшения"
        echo "  commit         - Сгенерировать commit message на основе git diff"
        echo "  quality [file] - Запустить mix quality (format, credo, dialyzer) с автоисправлением"
        echo "                  Опционально: дополнительная проверка конкретного файла"
        echo "  fix            - Найти и предложить исправления ошибок"
        echo "  docs <file>    - Сгенерировать документацию для модуля"
        echo ""
        echo "Примеры:"
        echo "  $0 context"
        echo "  $0 commit"
        echo "  $0 quality                    # Полная проверка проекта"
        echo "  $0 quality lib/phoenix_kit.ex # Проверка проекта + анализ файла"
        echo "  $0 fix"
        echo "  $0 docs lib/phoenix_kit/users/auth.ex"
        ;;
esac

echo ""