#!/bin/bash

# A script to set up and run the NatiqQuran API project.
# It handles Python environment setup, dependency installation, and initial data processing.

set -e

# --- Configuration ---
# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Mushaf identifiers (used to build filenames/paths consistently)
MUSHAF_SLUG="hafs"
MUSHAF_FULL_NAME="Hafs an Asem"
MUSHAF_SOURCE="tanzil"

# Data file paths (relative to the "parser" directory)
QURAN_XML="data/quran/quran-uthmani.xml"
TRANSLATIONS_SRC_DIR="data/translations/tanzil/"
TRANSLATIONS_OUT_DIR="translations"
MUSHAF_OUTPUT_JSON="${MUSHAF_SLUG}.json"

# Data file paths (relative to the "importer" directory, after generation)
PAGE_DIRECTORY="../parser/data/breakers/ayah_breakers/page.json"
HIZB_DIRECTORY="../parser/data/breakers/ayah_breakers/hizb.json"
JUZ_DIRECTORY="../parser/data/breakers/ayah_breakers/juz.json"

# --- Logging Functions ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Cleanup ---
cleanup() {
    log_warn "Cleaning up and deactivating virtualenv if active..."
    deactivate 2>/dev/null || true
}
trap cleanup EXIT

# --- Helper: run a python3 script.py command with proper error handling ---
# (Avoids relying on "$?" after the fact, which is unreliable under `set -e`,
#  since a non-zero exit would already terminate the script before the check runs.)
run_step() {
    local description="$1"
    shift
    log_info "$description"
    if ! "$@"; then
        log_error "$description -- FAILED"
        exit 1
    fi
}

# Navigate to the parent directory (project root, containing parser/ and importer/)
cd ..

# --- Prerequisite Checks ---
if ! command -v python3 &> /dev/null; then
    log_error "python3 not found. Please install Python 3."
    exit 1
fi

install_python_venv() {
    if [ -f /etc/debian_version ]; then
        log_warn "python3-venv not found. Installing for Debian/Ubuntu..."
        sudo apt-get update
        PY_VER=$(python3 -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}-venv")')
        sudo apt-get install -y "$PY_VER" python3-venv
    else
        log_error "python3-venv not found and automatic install is only supported on Debian/Ubuntu. Please install python3-venv manually."
        exit 1
    fi
}

if ! python3 -m venv --help &> /dev/null; then
    install_python_venv
fi

# --- Virtual Environment Setup ---
if [ ! -d ".venv" ]; then
    log_info "Creating virtual environment..."
    venv_output=$(python3 -m venv .venv 2>&1) || {
        if echo "$venv_output" | grep -q 'ensurepip is not available\|python.*-venv'; then
            log_warn "ensurepip/python3-venv is missing. Installing required packages..."
            install_python_venv
            rm -rf .venv
            log_info "Retrying virtual environment creation..."
            if ! python3 -m venv .venv; then
                log_error "Virtual environment creation failed again!"
                exit 1
            fi
        else
            log_error "Virtual environment creation failed!"
            echo "$venv_output"
            exit 1
        fi
    }
else
    log_info "Virtual environment already exists."
fi

if [ ! -f ".venv/bin/activate" ]; then
    log_error "Virtual environment activation script not found! Recreating..."
    rm -rf .venv
    log_info "Creating virtual environment..."
    venv_output=$(python3 -m venv .venv 2>&1) || {
        if echo "$venv_output" | grep -q 'ensurepip is not available\|python.*-venv'; then
            log_warn "ensurepip/python3-venv is missing. Installing required packages..."
            install_python_venv
            log_info "Retrying virtual environment creation..."
            if ! python3 -m venv .venv; then
                log_error "Virtual environment creation failed again!"
                exit 1
            fi
        else
            log_error "Failed to create virtual environment!"
            echo "$venv_output"
            exit 1
        fi
    }
fi

# Activate virtual environment
log_info "Activating virtual environment..."
source .venv/bin/activate

# --- Project Setup ---
log_info "Installing requirements..."
pip install -r requirements.txt

# --- Data Processing (parser) ---
cd parser

# quran <path_to_quran_xml_file> <mushaf_name> <mushaf_full_name> <mushaf_source> [--pretty]
run_step "Generating mushaf JSON (${MUSHAF_OUTPUT_JSON})..." \
    python3 script.py quran "$QURAN_XML" "$MUSHAF_SLUG" "$MUSHAF_FULL_NAME" "$MUSHAF_SOURCE" --pretty

# translation-bulk <path_to_translations_dir> <output_dir> <mushaf_slug> [--pretty]
run_step "Generating bulk translations..." \
    python3 script.py translation-bulk "$TRANSLATIONS_SRC_DIR" "$TRANSLATIONS_OUT_DIR" "$MUSHAF_SLUG" --pretty

cd ../importer

# --- Data Import ---
read -p "Server IP (e.g. http://localhost:8000): " SERVER_IP
read -p "Username: " USERNAME
read -s -p "Password: " PASSWORD
echo

# login <api_url> [username password] [--non-interactive]
run_step "Logging in to server..." \
    python3 script.py login "$SERVER_IP" "$USERNAME" "$PASSWORD" --non-interactive

# import-mushaf <input_json_file> <api_url>
run_step "Importing mushaf..." \
    python3 script.py import-mushaf "../parser/${MUSHAF_OUTPUT_JSON}" "$SERVER_IP"

# import-translations <translations_dir> <api_url>
run_step "Importing translations..." \
    python3 script.py import-translations "../parser/${TRANSLATIONS_OUT_DIR}" "$SERVER_IP"

# create-takhtit <api_url>
run_step "Creating takhtit..." \
    python3 script.py create-takhtit "$SERVER_IP"

# import-takhtit <json_file> <type> <api_url>
run_step "Importing pages..." \
    python3 script.py import-takhtit "$PAGE_DIRECTORY" "page" "$SERVER_IP"

run_step "Importing hizb..." \
    python3 script.py import-takhtit "$HIZB_DIRECTORY" "hizb" "$SERVER_IP"

run_step "Importing juz..." \
    python3 script.py import-takhtit "$JUZ_DIRECTORY" "juz" "$SERVER_IP"

log_success "All operations completed successfully!"
