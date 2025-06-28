#!/bin/sh
#
# create-uki.sh - A script to create a Unified Kernel Image for Alpine Linux.
#

set -e # Exit immediately if a command exits with a non-zero status.

# ---[ Configuration ]---------------------------------------------------------
CONFIG_FILE="/etc/uki.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found at $CONFIG_FILE" >&2
    exit 1
fi

# Source the configuration file
. "$CONFIG_FILE"

# ---[ Sanity Checks ]----------------------------------------------------------

# 1. Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# 2. Check for required tools
if ! command -v objcopy >/dev/null 2>&1; then
    echo "Error: objcopy command not found. Please install binutils." >&2
    exit 1
fi

# 3. Check that required paths and files exist
if [ ! -d "$ESP_PATH" ]; then
    echo "Error: EFI System Partition not found at $ESP_PATH" >&2
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Creating backup directory at $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
fi

if [ ! -f "$CMDLINE_PATH" ]; then
    echo "Error: Kernel cmdline file not found at $CMDLINE_PATH" >&2
    exit 1
fi

# ---[ Component Discovery ]----------------------------------------------------

echo "Discovering kernel components..."

# Find the latest kernel version
KERNEL_VERSION=$(ls /lib/modules | sort -V | tail -n 1)
KERNEL_IMAGE="/boot/vmlinuz-${KERNEL_VERSION#*-}"
INITRAMFS="/boot/initramfs-${KERNEL_VERSION#*-}"

if [ ! -f "$KERNEL_IMAGE" ]; then
    echo "Error: Kernel image not found at $KERNEL_IMAGE" >&2
    exit 1
fi

if [ ! -f "$INITRAMFS" ]; then
    echo "Error: Initramfs not found at $INITRAMFS" >&2
    exit 1
fi

# Determine CPU vendor and find microcode
CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
MICROCODE_PATH=""
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
    MICROCODE_PATH="/boot/intel-ucode.img"
    echo "Intel CPU detected. Using intel-ucode.img"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
    MICROCODE_PATH="/boot/amd-ucode.img"
    echo "AMD CPU detected. Using amd-ucode.img"
fi

if [ -n "$MICROCODE_PATH" ] && [ ! -f "$MICROCODE_PATH" ]; then
    echo "Warning: Microcode file not found at $MICROCODE_PATH. Continuing without it." >&2
    MICROCODE_PATH=""
fi

# Find the EFI stub
EFI_STUB="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
if [ ! -f "$EFI_STUB" ]; then
    echo "Error: EFI stub not found at $EFI_STUB" >&2
    echo "Please install systemd-boot-unsigned." >&2
    exit 1
fi

# ---[ UKI Assembly ]-----------------------------------------------------------

VERSIONED_UKI_NAME="${UKI_NAME%.efi}-${KERNEL_VERSION}.efi"
FINAL_UKI_PATH="$BACKUP_DIR/$VERSIONED_UKI_NAME"

echo "Assembling UKI: $FINAL_UKI_PATH"

# Prepare objcopy arguments
OBJCOPY_ARGS=""

# 1. Add OS release info
OBJCOPY_ARGS="$OBJCOPY_ARGS --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000"

# 2. Add kernel command line
OBJCOPY_ARGS="$OBJCOPY_ARGS --add-section .cmdline=$CMDLINE_PATH --change-section-vma .cmdline=0x30000"

# 3. Add splash image if specified
if [ -n "$SPLASH_IMAGE_PATH" ] && [ -f "$SPLASH_IMAGE_PATH" ]; then
    echo "Adding splash image: $SPLASH_IMAGE_PATH"
    OBJCOPY_ARGS="$OBJCOPY_ARGS --add-section .splash=$SPLASH_IMAGE_PATH --change-section-vma .splash=0x40000"
elif [ -n "$SPLASH_IMAGE_PATH" ]; then
    echo "Warning: Splash image not found at $SPLASH_IMAGE_PATH. Skipping."
fi

# 4. Add initrd (microcode + initramfs)
# We need to combine microcode and initramfs into a single file first
TEMP_INITRD=$(mktemp)
if [ -n "$MICROCODE_PATH" ]; then
    cat "$MICROCODE_PATH" "$INITRAMFS" > "$TEMP_INITRD"
else
    cat "$INITRAMFS" > "$TEMP_INITRD"
fi
OBJCOPY_ARGS="$OBJCOPY_ARGS --add-section .initrd=$TEMP_INITRD --change-section-vma .initrd=0x3000000"

# 5. Add the kernel image
OBJCOPY_ARGS="$OBJCOPY_ARGS --add-section .linux=$KERNEL_IMAGE --change-section-vma .linux=0x2000000"

# Build the UKI
objcopy \
    $OBJCOPY_ARGS \
    "$EFI_STUB" "$FINAL_UKI_PATH"

# Clean up temporary initrd file
rm "$TEMP_INITRD"

echo "UKI created successfully."

# ---[ Installation and Cleanup ]-----------------------------------------------

ESP_UKI_PATH="$ESP_PATH/EFI/BOOT/$UKI_NAME"
echo "Installing UKI to $ESP_UKI_PATH"
cp "$FINAL_UKI_PATH" "$ESP_UKI_PATH"

echo "Cleaning up old backups..."
# List all backups, sort them by version, and keep only the newest ones.
ls -1 "$BACKUP_DIR" | grep "^${UKI_NAME%.efi}-" | sort -V | head -n -${RETAIN_COUNT} | while read -r old_uki; do
    echo "Removing old backup: $old_uki"
    rm -f "$BACKUP_DIR/$old_uki"
done

echo "Done."

