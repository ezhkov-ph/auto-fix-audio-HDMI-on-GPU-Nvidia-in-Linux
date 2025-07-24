#!/bin/bash

# ==============================================================================
#  Скрипт для автоматического исправления проблем со звуком HDMI на Nvidia
#  1. Устраняет "засыпание" аудиокарты (задержка перед воспроизведением).
#  2. Устраняет прерывания звука (статтеры) путем блокировки P-State.
# ==============================================================================

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- ПРОВЕРКИ ПЕРЕД ЗАПУСКОМ ---

# 1. Проверка запуска от имени root (sudo)
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Этот скрипт необходимо запустить с правами sudo.${NC}"
   echo "Попробуйте: sudo ./fix_hdmi_audio.sh"
   exit 1
fi

# 2. Проверка наличия пользователя, от имени которого запущен sudo
if [ -z "$SUDO_USER" ]; then
    echo -e "${RED}Ошибка: Не удалось определить обычного пользователя. Запустите скрипт через 'sudo' из-под вашей учетной записи.${NC}"
    exit 1
fi
USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)

# 3. Проверка наличия драйвера Nvidia
if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${RED}Ошибка: Команда 'nvidia-smi' не найдена. Убедитесь, что драйверы Nvidia установлены.${NC}"
    exit 1
fi

echo -e "${GREEN}Все проверки пройдены. Начинаю настройку...${NC}"

# --- ЧАСТЬ 1: УСТРАНЕНИЕ ЗАСЫПАНИЯ АУДИО ---

echo -e "\n${YELLOW}Шаг 1.1: Отключение энергосбережения аудио на уровне ядра...${NC}"
cat > /etc/modprobe.d/nvidia-hdmi-audio-powersave-off.conf <<EOF
# Отключает энергосбережение для Intel HDA, используемого Nvidia HDMI
options snd_hda_intel power_save=0
options snd_hda_intel power_save_controller=N
EOF
echo -e "${GREEN}Файл /etc/modprobe.d/nvidia-hdmi-audio-powersave-off.conf создан.${NC}"

echo -e "\n${YELLOW}Шаг 1.2: Настройка WirePlumber для постоянной активности HDMI...${NC}"
WP_CONFIG_DIR="$USER_HOME/.config/wireplumber/main.lua.d"
WP_SYSTEM_CONFIG="/usr/share/wireplumber/main.lua.d/50-alsa-config.lua"
WP_USER_CONFIG="$WP_CONFIG_DIR/50-alsa-config.lua"

mkdir -p "$WP_CONFIG_DIR"
chown "$SUDO_USER:$SUDO_USER" "$WP_CONFIG_DIR" -R
cp "$WP_SYSTEM_CONFIG" "$WP_USER_CONFIG"

# Используем sed для добавления настроек, не перезаписывая весь файл
sed -i '/apply_properties = {/a \        ["session.suspend-timeout-seconds"] = 0, -- No suspend\n        ["node.pause-on-idle"] = false,    -- No idle pause' "$WP_USER_CONFIG"
chown "$SUDO_USER:$SUDO_USER" "$WP_USER_CONFIG"
echo -e "${GREEN}Конфигурация WirePlumber для пользователя $SUDO_USER создана и изменена.${NC}"


# --- ЧАСТЬ 2: УСТРАНЕНИЕ ПРЕРЫВАНИЙ (БЛОКИРОВКА P-STATES) ---

echo -e "\n${YELLOW}Шаг 2.1: Автоматическое определение максимальных частот GPU...${NC}"
MAX_GPU_CLOCK=$(nvidia-smi --query-supported-clocks=graphics --format=csv,noheader,nounits | sed 's/,.*//' | sort -n | tail -n 1)
MAX_MEM_CLOCK=$(nvidia-smi --query-supported-clocks=memory --format=csv,noheader,nounits | sed 's/,.*//' | sort -n | tail -n 1)

if [[ -z "$MAX_GPU_CLOCK" || -z "$MAX_MEM_CLOCK" ]]; then
    echo -e "${RED}Ошибка: Не удалось определить максимальные частоты. Прекращение работы.${NC}"
    exit 1
fi
echo -e "${GREEN}Определены частоты: GPU=$MAX_GPU_CLOCK MHz, Memory=$MAX_MEM_CLOCK MHz.${NC}"

echo -e "\n${YELLOW}Шаг 2.2: Создание скрипта для фиксации производительности...${NC}"
SCRIPT_PATH="/usr/local/bin/nvidia-performance-fix.sh"
tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
sleep 10
/usr/bin/nvidia-settings -a '[gpu:0]/GpuPowerMizerMode=1'
/usr/bin/nvidia-smi --lock-gpu-clocks=$MAX_GPU_CLOCK
/usr/bin/nvidia-smi --lock-memory-clocks=$MAX_MEM_CLOCK
EOF
chmod +x "$SCRIPT_PATH"
echo -e "${GREEN}Скрипт $SCRIPT_PATH создан.${NC}"

echo -e "\n${YELLOW}Шаг 2.3: Создание службы systemd для автозапуска...${NC}"
SERVICE_PATH="/etc/systemd/system/nvidia-performance-fix.service"
tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Nvidia Performance Fix for HDMI Audio Stutter
After=graphical.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH

[Install]
WantedBy=graphical.target
EOF
echo -e "${GREEN}Служба $SERVICE_PATH создана.${NC}"


# --- ЧАСТЬ 3: ФИНАЛИЗАЦИЯ ---

echo -e "\n${YELLOW}Шаг 3: Активация службы...${NC}"
systemctl daemon-reload
systemctl enable nvidia-performance-fix.service
echo -e "${GREEN}Служба nvidia-performance-fix.service включена.${NC}"

echo -e "\n\n${GREEN}====================================================="
echo -e "      НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "=====================================================${NC}"
echo -e "${YELLOW}Чтобы все изменения вступили в силу, необходимо перезагрузить компьютер.${NC}"
echo -e "Выполните команду: ${GREEN}reboot${NC}"

exit 0
