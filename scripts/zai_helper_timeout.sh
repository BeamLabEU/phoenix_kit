#!/bin/bash

# Функция для вызова Z.AI с тайм-аутом
zai_with_timeout() {
    local prompt=$1
    local timeout=${2:-30}  # Тайм-аут по умолчанию 30 секунд
    local output_file="/tmp/zai_output_$$.txt"

    echo "Запрашиваю у Z.AI (тайм-аут: ${timeout}с)..."

    # Запускаем zai в фоне
    (
        source /root/.bashrc 2>/dev/null
        zai "$prompt" --print > "$output_file" 2>&1
    ) &
    local pid=$!

    # Ждём завершения с тайм-аутом
    local count=0
    while kill -0 $pid 2>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [ $count -ge $timeout ]; then
            kill $pid 2>/dev/null
            echo "⚠️ Тайм-аут истёк. Z.AI не успел ответить за ${timeout} секунд"
            echo "Продолжаю без предложений Z.AI..."
            return 1
        fi
    done

    # Если успешно завершился
    if [ -f "$output_file" ]; then
        cat "$output_file"
        rm "$output_file"
        return 0
    fi

    return 1
}

# Пример использования
if [ "$1" = "test" ]; then
    zai_with_timeout "What is 2+2?" 10
fi