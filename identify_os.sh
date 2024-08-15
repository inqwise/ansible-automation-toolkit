#!/bin/bash

# Function to identify the Linux OS family and version
identify_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                OS_FAMILY="debian"
                ;;
            centos|rhel|fedora|rocky|almalinux)
                OS_FAMILY="redhat"
                ;;
            suse|opensuse)
                OS_FAMILY="suse"
                ;;
            arch)
                OS_FAMILY="arch"
                ;;
            amzn)
                OS_FAMILY="amzn"
                OS_VERSION="$VERSION_ID"
                OS_VERSION_MAJOR="${OS_VERSION%%.*}"
                ;;
            *)
                OS_FAMILY="unknown"
                OS_VERSION="unknown"
                OS_VERSION_MAJOR="unknown"
                ;;
        esac
    elif [ -f /etc/system-release ]; then
        # Handling older Amazon Linux (Original)
        if grep -q "Amazon Linux" /etc/system-release; then
            OS_FAMILY="amzn"
            OS_VERSION=$(grep -o "[0-9]\+" /etc/system-release | head -1)
            OS_VERSION_MAJOR="${OS_VERSION%%.*}"
        else
            OS_FAMILY="unknown"
            OS_VERSION="unknown"
            OS_VERSION_MAJOR="unknown"
        fi
    else
        OS_FAMILY="unknown"
        OS_VERSION="unknown"
        OS_VERSION_MAJOR="unknown"
    fi
}

# Call the function to identify the OS family and version
identify_os

# Save the OS family, version, and major version to environment variables
export OS_FAMILY
export OS_VERSION
export OS_VERSION_MAJOR

# Print the results (optional)
echo "Detected OS Family: $OS_FAMILY"
echo "Detected OS Version: $OS_VERSION"
echo "Detected OS Major Version: $OS_VERSION_MAJOR"