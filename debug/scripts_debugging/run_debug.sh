#!/bin/bash

set -euo pipefail
DEBUG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBUG_ROOT="$(cd "$DEBUG_SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEBUG_ROOT/.." && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$DEBUG_ROOT/../sources}"
PROJECT_KEY="${DEBUG_PROJECT_KEY:-$(basename "$SOURCE_ROOT")}"

RUN_MODE="interactive"
NON_INTERACTIVE="false"

usage() {
    echo "Usage: $0 [--mode interactive|direct|lldb|lldb-main|vscode] [--non-interactive]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            RUN_MODE="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE="true"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Build-type aware install root and app locations
# BUILD_TYPE can be: Debug, Release, RelWithDebInfo, MinSizeRel
BUILD_TYPE="${BUILD_TYPE:-Debug}"
BUILD_LABEL="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
DEBUG_INSTALL_DIR="$DEBUG_ROOT/../builds/debug/$PROJECT_KEY/$BUILD_LABEL/install"
CONFIG_DIR="$BUILD_TYPE"
INSTALL_CONFIG_DIR="$DEBUG_INSTALL_DIR/$CONFIG_DIR"
if [ -d "$INSTALL_CONFIG_DIR" ]; then
    INSTALL_BASE="$INSTALL_CONFIG_DIR"
else
    INSTALL_BASE="$DEBUG_INSTALL_DIR"
fi

APP_NAME="${APP_NAME:-ManiVault Studio.app}"
APP_PATH="$INSTALL_BASE/$APP_NAME"
FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"
PLUGINS_PATH="$APP_PATH/Contents/Plugins"

resolve_qt_dir() {
    QT_DIR="${QT_DIR:-}"
    if [ -n "$QT_DIR" ] && [ -d "$QT_DIR/bin" ] && [ -d "$QT_DIR/lib" ]; then
        return 0
    fi

    local candidates=(
        "$HOME/Qt/6.10.3/macos"
        "$HOME/Qt/6.8.2/macos"
        "$HOME/Qt/6.8.1/macos"
        "/opt/homebrew/opt/qt"
        "/usr/local/opt/qt"
    )

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate/bin" ] && [ -d "$candidate/lib" ]; then
            QT_DIR="$candidate"
            return 0
        fi
    done

    if command -v qmake >/dev/null 2>&1; then
        local qmake_path
        qmake_path="$(command -v qmake)"
        QT_DIR="$(cd "$(dirname "$qmake_path")/.." && pwd)"
        return 0
    fi

    echo "Could not detect Qt location. Set QT_DIR and retry."
    exit 1
}

# Validate install/app paths and fallback to first available .app if needed
if [ ! -d "$DEBUG_INSTALL_DIR" ]; then
    echo "Expected install root not found: $DEBUG_INSTALL_DIR"
    echo "Hint: Run the build script first (e.g., BUILD_TYPE=$BUILD_TYPE ./debug/scripts_debugging/build_debug.sh)"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    # Try to locate any .app under config-aware or flat install roots
    ALT_APP=""
    if [ -d "$INSTALL_BASE" ]; then
        ALT_APP=$(ls -1d "$INSTALL_BASE"/*.app 2>/dev/null | head -n 1)
    fi
    if [ -z "$ALT_APP" ]; then
        ALT_APP=$(find "$DEBUG_INSTALL_DIR" -type d -name "*.app" -print | head -n 1)
    fi
    if [ -n "$ALT_APP" ]; then
        echo "Info: Using detected app bundle: $ALT_APP"
        APP_PATH="$ALT_APP"
        FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"
        PLUGINS_PATH="$APP_PATH/Contents/Plugins"
    else
        echo "Could not find app bundle ($APP_NAME) under $INSTALL_BASE or $DEBUG_INSTALL_DIR"
        exit 1
    fi
fi

# Optionally set up environment variables for Qt, plugins, etc.
resolve_qt_dir
export PATH="$QT_DIR/bin:$PATH"
export DYLD_LIBRARY_PATH="$QT_DIR/lib:$FRAMEWORKS_PATH:$DYLD_LIBRARY_PATH"

# Find the main executable inside the .app bundle
EXE_PATH=$(find "$APP_PATH/Contents/MacOS" -type f -perm -111 -print | head -n 1)
if [ -z "$EXE_PATH" ]; then
    echo "Could not find main executable in $APP_PATH/Contents/MacOS"
    exit 1
fi

# Interactive run options
PS3="Choose debug run option [BUILD_TYPE=$BUILD_TYPE]: "
options=(
    "Run directly"
    "Run with custom arguments"
    "Run with custom environment variables"
    "Run and save output"
    "Run with verbose logging"
    "Run with lldb"
    "Run with lldb (break at main)"
    "Open in VS Code and start debugging"
    "Run with gdb"
    "Run with Guard Malloc (memory debugging)"
    "Run with Address Sanitizer"
    "Run with Valgrind (memory analysis)"
    "Run with Instruments (performance profiling)"
    "Run with dtruss (system call trace, sudo)"
    "Run with Qt debug logging"
    "Print environment info"
    "Advanced: Debug ScatterplotPlugin crash"
    "Advanced: Debug ActionsListModel crash (MainWindow init)"
    "Advanced: Debug post-project-load crash"
    "Advanced: Debug system malloc issue (XPC/dyld)"
    "Run without malloc debugging"
    "Exit"
)

show_and_run() {
    local cmd="$1"
    echo "\n--- Command to be executed ---"
    echo "$cmd"
    echo "-----------------------------"
    read -p "Press Enter to run, or Ctrl+C to cancel..."
    # Always quote the executable path if present in the command
    # Replace $EXE_PATH with "$EXE_PATH" in the command string
    if [[ "$cmd" == *"$EXE_PATH"* ]]; then
        cmd="${cmd//$EXE_PATH/\"$EXE_PATH\"}"
    fi
    eval "$cmd"
}

find_vscode_cli() {
    if command -v code >/dev/null 2>&1; then
        command -v code
        return 0
    fi

    local candidates=(
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code"
    )

    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

open_in_vscode() {
    local code_bin
    local config_name=""
    local debug_payload=""
    local debug_uri=""

    if ! code_bin="$(find_vscode_cli)"; then
        echo "Could not find a VS Code command-line launcher."
        echo "Open the workspace in VS Code and use Debug: Select and Start Debugging."
        return 1
    fi

    case "$PROJECT_KEY" in
        manivault-installer)
            config_name="Debug manivault-installer"
            debug_payload="%5B%7B%22config%22%3A%7B%22name%22%3A%22Debug%20manivault-installer%22%7D%7D%5D"
            ;;
        cytosplore-installer)
            config_name="Debug cytosplore-installer"
            debug_payload="%5B%7B%22config%22%3A%7B%22name%22%3A%22Debug%20cytosplore-installer%22%7D%7D%5D"
            ;;
        manivault-installer-main)
            config_name="Debug manivault-installer-main"
            debug_payload="%5B%7B%22config%22%3A%7B%22name%22%3A%22Debug%20manivault-installer-main%22%7D%7D%5D"
            ;;
        debug-simple)
            config_name="Debug debug-simple"
            debug_payload="%5B%7B%22config%22%3A%7B%22name%22%3A%22Debug%20debug-simple%22%7D%7D%5D"
            ;;
        *)
            config_name=""
            debug_payload=""
            ;;
    esac

    if [ -n "$debug_payload" ]; then
        debug_uri="vscode://command/workbench.action.debug.start?$debug_payload"
    else
        debug_uri="vscode://command/workbench.action.debug.start"
    fi

    echo "\n--- VS Code Debug Command ---"
    echo "$code_bin --reuse-window \"$REPO_ROOT\""
    echo "open \"$debug_uri\""
    echo "-----------------------------"

    # Open/reuse the workspace window first, then trigger the debug command via URI.
    "$code_bin" --reuse-window "$REPO_ROOT" >/dev/null 2>&1 || true
    sleep 0.4

    open "$debug_uri" >/dev/null 2>&1 || true

    # Strong fallback: trigger Run > Start Debugging directly from the VS Code menu.
    # This is often more reliable than command URIs on some macOS setups.
    local menu_output
    local menu_rc=1
    local menu_attempt
    for menu_attempt in 1 2 3 4 5 6; do
        menu_output="$(osascript <<'APPLESCRIPT' 2>&1
tell application "Visual Studio Code" to activate
delay 0.3
tell application "System Events"
  tell process "Code"
    click menu item "Start Debugging" of menu "Run" of menu bar 1
  end tell
end tell
APPLESCRIPT
        )"
        menu_rc=$?
        if [ $menu_rc -eq 0 ]; then
            return 0
        fi
        if [[ "$menu_output" == *"Connection is invalid"* ]]; then
            sleep 0.4
            continue
        fi
        break
    done

    if [[ "$menu_output" == *"not allowed to send keystrokes"* ]] || [[ "$menu_output" == *"not allowed assistive access"* ]]; then
        echo ""
        echo "VS Code debug handoff was blocked by macOS Accessibility permissions."
        echo "Enable Accessibility for your terminal app and Visual Studio Code, then retry."
        echo "Quick open: System Settings -> Privacy & Security -> Accessibility"
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
        return 1
    fi

    # Fallback for cases where command URIs are accepted but do not actually start debugging.
    # This drives VS Code's command palette to launch the expected debug configuration.
    if [ -n "$config_name" ]; then
        local osa_output
        local osa_rc=1
        local attempt
        for attempt in 1 2 3 4 5 6 7 8; do
            osa_output="$(VSCODE_DEBUG_CONFIG_NAME="$config_name" osascript <<'APPLESCRIPT' 2>&1
on run
    set debugConfig to system attribute "VSCODE_DEBUG_CONFIG_NAME"
    tell application "Visual Studio Code" to activate
    delay 0.4
    tell application "System Events"
        keystroke "p" using {command down, shift down}
        delay 0.3
        keystroke "Debug: Select and Start Debugging"
        key code 36
        delay 0.5
        keystroke debugConfig
        delay 0.3
        key code 36
    end tell
end run
APPLESCRIPT
            )"
            osa_rc=$?
            if [ $osa_rc -eq 0 ]; then
                break
            fi
            if [[ "$osa_output" == *"Connection is invalid"* ]]; then
                sleep 0.4
                continue
            fi
            break
        done

        if [ $osa_rc -ne 0 ]; then
            if [[ "$osa_output" == *"not allowed to send keystrokes"* ]]; then
                echo ""
                echo "VS Code debug handoff was blocked by macOS Accessibility permissions."
                echo "Enable Accessibility for your terminal app and Visual Studio Code, then retry."
                echo "Quick open: System Settings -> Privacy & Security -> Accessibility"
                open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
                return 1
            fi
            echo ""
            echo "VS Code debug handoff automation failed:"
            echo "$osa_output"
            return 1
        fi

        return 0
    fi

    # Fallbacks for older command handling paths.
    open "vscode://command/workbench.action.debug.start" >/dev/null 2>&1 || true
    open "vscode://command/workbench.action.debug.selectAndStartDebugging" >/dev/null 2>&1 || true
}

run_mode_command() {
    case "$RUN_MODE" in
        interactive)
            return 1
            ;;
        direct)
            show_and_run "$EXE_PATH"
            return 0
            ;;
        lldb)
            show_and_run "lldb $EXE_PATH"
            return 0
            ;;
        lldb-main)
            show_and_run "lldb -o 'breakpoint set --name main' -o run $EXE_PATH"
            return 0
            ;;
        vscode)
            open_in_vscode
            return $?
            ;;
        *)
            echo "Unsupported --mode value: $RUN_MODE"
            usage
            ;;
    esac
}

if [ "$NON_INTERACTIVE" = "true" ]; then
    show_and_run() {
        local cmd="$1"
        echo "\n--- Command to be executed ---"
        echo "$cmd"
        echo "-----------------------------"
        if [[ "$cmd" == *"$EXE_PATH"* ]]; then
            cmd="${cmd//$EXE_PATH/\"$EXE_PATH\"}"
        fi
        eval "$cmd"
    }
fi

if run_mode_command; then
    exit 0
fi

select opt in "${options[@]}"; do
    case $REPLY in
        1)
            echo "\n--- Direct Run Tips ---"
            echo "App will run normally. Use Ctrl+C to quit."
            echo "If you need debug info, use other options."
            echo "-----------------------------\n"
            show_and_run "$EXE_PATH"
            break
            ;;
        2)
            echo "\n--- Custom Arguments Tips ---"
            echo "Enter arguments as you would on the command line."
            echo "Example: --help or inputfile.txt"
            echo "App will run with your arguments. Use Ctrl+C to quit."
            echo "-----------------------------\n"
            read -p "Enter custom arguments: " CUSTOM_ARGS
            show_and_run "$EXE_PATH $CUSTOM_ARGS"
            break
            ;;
        3)
            echo "\n--- Custom Environment Tips ---"
            echo "Enter environment variables as VAR=value pairs."
            echo "Example: FOO=1 BAR=2"
            echo "App will run with these variables set. Use Ctrl+C to quit."
            echo "-----------------------------\n"
            read -p "Enter environment variables (e.g. FOO=1 BAR=2): " CUSTOM_ENV
            show_and_run "$CUSTOM_ENV $EXE_PATH"
            break
            ;;
        4)
            echo "\n--- Save Output Tips ---"
            echo "App output will be saved to a timestamped file."
            echo "Check the output file after run for logs/errors."
            echo "-----------------------------\n"
            DEBUG_OUTPUT_DIR="$DEBUG_ROOT/../builds/debug/logs"
            mkdir -p "$DEBUG_OUTPUT_DIR"
            TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
            OUTPUT_FILE="$DEBUG_OUTPUT_DIR/debug_run_$TIMESTAMP.txt"
            show_and_run "$EXE_PATH &> $OUTPUT_FILE"
            echo "Output saved to $OUTPUT_FILE"
            break
            ;;
        5)
            echo "\n--- Verbose Logging Tips ---"
            echo "App will run with MV_DEBUG=1 for extra debug output."
            echo "Look for debug messages in the terminal."
            echo "-----------------------------\n"
            show_and_run "MV_DEBUG=1 $EXE_PATH"
            break
            ;;
        6)
            echo "\n--- LLDB Debugger Tips ---"
            echo "At the lldb prompt, you can use these commands:"
            echo "  run         : Start the program"
            echo "  continue    : Resume after a breakpoint"
            echo "  exit/quit   : Exit lldb"
            echo "  breakpoint set --name <func> : Set a breakpoint at function"
            echo "  break list  : List breakpoints"
            echo "  bt          : Show backtrace (call stack)"
            echo "  help        : Show lldb help"
            echo "-----------------------------\n"
            show_and_run "lldb $EXE_PATH"
            break
            ;;
        7)
            echo "\n--- LLDB (break at main) Tips ---"
            echo "App will break at main(). Use continue to resume."
            echo "Set more breakpoints as needed."
            echo "-----------------------------\n"
            show_and_run "lldb -o 'breakpoint set --name main' -o run $EXE_PATH"
            break
            ;;
        8)
            echo "\n--- VS Code Debug Tips ---"
            echo "VS Code will open and show the debug configuration picker."
            echo "Pick the configuration for this project, then debug starts in the editor."
            echo "-----------------------------\n"
            open_in_vscode
            break
            ;;
        9)
            echo "\n--- GDB Debugger Tips ---"
            echo "At the gdb prompt, use:"
            echo "  run, continue, break, bt, quit"
            echo "Type help for more commands."
            echo "-----------------------------\n"
            show_and_run "gdb $EXE_PATH"
            break
            ;;
        10)
            echo "\n--- Guard Malloc Tips ---"
            echo "App will run with malloc debugging enabled."
            echo "Look for memory errors in the output."
            echo "-----------------------------\n"
            export MallocGuardEdges=1
            export MallocScribble=1
            export MallocCheckHeapStart=1
            export MallocCheckHeapEach=100
            show_and_run "$EXE_PATH"
            break
            ;;
        11)
            echo "\n--- Address Sanitizer Tips ---"
            echo "App will run with ASAN enabled."
            echo "Look for sanitizer errors in the output."
            echo "-----------------------------\n"
            export ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:print_stats=1"
            show_and_run "$EXE_PATH"
            break
            ;;
        12)
            echo "\n--- Valgrind Tips ---"
            echo "App will run under Valgrind for memory analysis."
            echo "Look for memory leaks and errors in the output."
            echo "-----------------------------\n"
            if command -v valgrind &> /dev/null; then
                show_and_run "valgrind $EXE_PATH"
            else
                echo "Valgrind not found. Please install it."
            fi
            break
            ;;
        13)
            echo "\n--- Instruments Tips ---"
            echo "App will run with Time Profiler."
            echo "Use Instruments UI to analyze performance."
            echo "-----------------------------\n"
            if command -v instruments &> /dev/null; then
                show_and_run "instruments -t 'Time Profiler' $EXE_PATH"
            else
                echo "Instruments not found. Please install Xcode Command Line Tools."
            fi
            break
            ;;
        14)
            echo "\n--- dtruss Tips ---"
            echo "App will run with system call tracing (sudo required)."
            echo "Look for syscall info in the output."
            echo "-----------------------------\n"
            show_and_run "sudo dtruss $EXE_PATH"
            break
            ;;
        15)
            echo "\n--- Qt Debug Logging Tips ---"
            echo "App will run with extra Qt debug output."
            echo "Look for Qt debug messages in the terminal."
            echo "-----------------------------\n"
            export QT_LOGGING_RULES="qt.qpa.cocoa.debug=true;qt.widgets.debug=true;qt.core.debug=true"
            export QT_MESSAGE_PATTERN="[%{time yyyyMMdd h:mm:ss.zzz t} %{if-debug}D%{endif}%{if-warning}W%{endif}%{if-critical}C%{endif}%{if-fatal}F%{endif}] %{file}:%{line} - %{message}"
            show_and_run "$EXE_PATH"
            break
            ;;
        16)
            echo "\n--- Environment Info Tips ---"
            echo "Shows current environment variables and paths."
            echo "Use this for troubleshooting build/run issues."
            echo "-----------------------------\n"
            echo "--- Environment Info ---"
            echo "PATH=$PATH"
            echo "DYLD_LIBRARY_PATH=$DYLD_LIBRARY_PATH"
            echo "QT_DIR=$QT_DIR"
            echo "BUILD_TYPE=$BUILD_TYPE"
            echo "BUILD_LABEL=$BUILD_LABEL"
            echo "INSTALL_ROOT=$DEBUG_INSTALL_DIR"
            echo "INSTALL_BASE=$INSTALL_BASE"
            echo "App Path: $APP_PATH"
            echo "Executable: $EXE_PATH"
            echo "------------------------"
            ;;
        17)
            echo "\n--- Advanced LLDB: ScatterplotPlugin Crash ---"
            echo "Will set breakpoints for ScatterplotPlugin and memory errors."
            echo "Use lldb commands as needed."
            echo "-----------------------------\n"
            cat > /tmp/scatterplot_debug_commands.lldb << 'EOF'
breakpoint set --name ScatterplotPlugin::updateHeadsUpDisplay
breakpoint set --name QPersistentModelIndexData::create
breakpoint set --name "mv::AbstractHeadsUpDisplayModel::addHeadsUpDisplayItem"
breakpoint set --name malloc_error_break
settings set target.env-vars MallocGuardEdges=1
settings set target.env-vars MallocScribble=1
settings set target.env-vars MallocCheckHeapStart=1
breakpoint command add -o "frame variable" -o "bt" -o "continue" 1
breakpoint set --name _libxpc_initializer
breakpoint command add -o "continue" -1
run
print (char*)$rdi
memory read $rdi $rdi+64
register read
bt
EOF
            show_and_run "lldb -s /tmp/scatterplot_debug_commands.lldb $EXE_PATH"
            break
            ;;
        18)
            echo "\n--- Advanced LLDB: ActionsListModel Crash ---"
            echo "Will set breakpoints for ActionsListModel and memory errors."
            echo "Use lldb commands as needed."
            echo "-----------------------------\n"
            cat > /tmp/actions_model_debug.lldb << 'EOF'
breakpoint set --file ActionsListModel.cpp --line 67
breakpoint command add -o "frame variable" -o "print action" -o "print this" -o "continue" -1
breakpoint set --name "QMenu::clear"
breakpoint command add -o "frame variable this" -o "continue" -1
breakpoint set --name "MainWindow::initialize"
breakpoint command add -o "print \"=== MainWindow::initialize() starting ===\"" -o "continue" -1
breakpoint set --name "ViewMenu::ViewMenu"
breakpoint command add -o "frame variable" -o "continue" -1
breakpoint set --name abort
breakpoint set --name malloc_error_break
breakpoint set --name QPersistentModelIndexData::create
breakpoint condition -1 'index == 0 || index->model() == 0'
run
print "=== CRASH DETECTED ==="
frame variable
up 5
frame variable action
frame variable this
EOF
            show_and_run "lldb -s /tmp/actions_model_debug.lldb $EXE_PATH"
            break
            ;;
        19)
            echo "\n--- Advanced LLDB: Post-Project-Load Crash ---"
            echo "Will set breakpoints for post-project-load analysis."
            echo "Use lldb commands as needed."
            echo "-----------------------------\n"
            cat > /tmp/post_project_debug.lldb << 'EOF'
breakpoint set --name ScatterplotPlugin::updateHeadsUpDisplay
breakpoint set --name ScatterplotPlugin::fromVariantMap
breakpoint set --name QPersistentModelIndexData::create
breakpoint set --name "mv::AbstractHeadsUpDisplayModel::addHeadsUpDisplayItem"
breakpoint set --name QPersistentModelIndex::QPersistentModelIndex
breakpoint set --name abort
breakpoint set --name __assert_rtn
breakpoint set --name malloc_error_break
settings set target.env-vars MallocScribble=1
breakpoint command add 1 -o "frame variable" -o "register read" -o "bt" -o "continue"
breakpoint command add 2 -o "frame variable this" -o "bt" -o "continue"
breakpoint command add 3 -o "frame variable index" -o "bt"
breakpoint command add 4 -o "frame variable headsUpDisplayItem" -o "bt"
run
print "=== CRASH ANALYSIS ==="
register read
bt
frame variable
thread backtrace all
EOF
            show_and_run "lldb -s /tmp/post_project_debug.lldb $EXE_PATH"
            break
            ;;
        20)
            echo "\n--- Advanced LLDB: System Malloc Debug ---"
            echo "Will set breakpoints for malloc errors and system issues."
            echo "Use lldb commands as needed."
            echo "-----------------------------\n"
            cat > /tmp/system_malloc_debug.lldb << 'EOF'
breakpoint set --name malloc_error_break
breakpoint set --name abort
breakpoint set --name main
breakpoint command add -o "continue" -1
breakpoint set --name QPersistentModelIndexData::create
breakpoint set --name ScatterplotPlugin::updateHeadsUpDisplay
settings set target.env-vars MallocScribble=1
run
EOF
            show_and_run "lldb -s /tmp/system_malloc_debug.lldb $EXE_PATH"
            break
            ;;
        21)
            echo "\n--- Run Without Malloc Debugging Tips ---"
            echo "App will run normally, without malloc debugging."
            echo "Use Ctrl+C to quit."
            echo "-----------------------------\n"
            show_and_run "$EXE_PATH"
            break
            ;;
        22)
            echo "\n--- Exit Tips ---"
            echo "Exiting the debug script."
            echo "-----------------------------\n"
            echo "Exiting."
            break
            ;;
        *)
            echo "Invalid option."
            ;;
    esac
done

#bt //prints the backtrace of all the function calls that led to the current point of execution. 
#frame select 2 //selects the stack frame at index 2, allowing to inspect variables and state at that level.
#list //displays the source code around the current line in the selected frame.
#frame variable //lists all local variables in the current frame along with their values.
#up 5 //moves up 5 frames in the call stack, allowing to inspect higher-level function calls.
#frame variable action //displays the value of the variable named action in the current frame.
#frame variable this //displays the value of the variable named this in the current frame.
#quit //exits the debugger.
#breakpoint set --name <function_name> //sets a breakpoint at the specified function, pausing execution when that function is called.
#run //starts the execution of the program being debugged.
#continue //resumes execution after hitting a breakpoint.
#print (char*)$rdi //prints the contents of the register rdi, interpreted
#memory read $rdi $rdi+64 //reads and displays 64 bytes of memory starting from the address in rdi.
#register read //displays the current values of all CPU registers.
#settings set target.env-vars VAR=value //sets an environment variable VAR to value for the debugged program.
#breakpoint command add -o "commands" -o "continue" <breakpoint_id> //adds commands to be executed automatically when the specified breakpoint is hit.
#breakpoint condition -1 'condition' //adds a condition to the last set breakpoint, so it only triggers when the condition is true.
#thread backtrace all //prints the backtrace for all threads in the program.
#breakpoint set --file <filename> --line <line_number> //sets a breakpoint at the specified line in the given source file.
#breakpoint set --name abort //sets a breakpoint at the abort function, which is often called when a fatal error occurs.
#breakpoint set --name malloc_error_break //sets a breakpoint at the malloc_error_break function, which is called on memory allocation errors.
#breakpoint set --name QPersistentModelIndexData::create //sets a breakpoint at the create method of the QPersistentModelIndexData class.
#breakpoint set --name ScatterplotPlugin::updateHeadsUpDisplay //sets a breakpoint at the updateHeadsUpDisplay method of the ScatterplotPlugin class.
#breakpoint set --name "mv::AbstractHeadsUpDisplayModel::addHeadsUpDisplayItem" //sets a breakpoint at the addHeadsUpDisplayItem method of the mv::AbstractHeadsUpDisplayModel class.
#breakpoint set --name MainWindow::initialize //sets a breakpoint at the initialize method of the MainWindow class.
#breakpoint set --name ViewMenu::ViewMenu //sets a breakpoint at the constructor of the ViewMenu class.
#breakpoint set --name __assert_rtn //sets a breakpoint at the __assert_rtn function, which is called when an assertion fails.
#breakpoint set --      name _libxpc_initializer //sets a breakpoint at the _libxpc_initializer function, which is part of the XPC library initialization.
#settings set target.env-vars MallocGuardEdges=1 //enables guard edges for malloc, which helps detect buffer overflows.
#settings set target.env-vars MallocScribble=1 //enables scribbling of freed memory, which helps detect use-after-free errors.
#settings set target.env-vars MallocCheckHeapStart=1 //enables heap checking at the start of malloc operations.
#settings set target.env-vars MallocCheckHeapEach=100 //enables heap checking after every 100 malloc operations.
#settings set target.env-vars ASAN_OPTIONS="options" //sets options for Address Sanitizer, a memory error detector.
#export VAR=value //sets an environment variable VAR to value for the current shell session.
#cat > /tmp/file.lldb << 'EOF' ... EOF //creates a temporary LLDB command script with the specified commands.   
#lldb -s /tmp/file.lldb $EXE_PATH //starts LLDB with the commands from the specified script file and the given executable.
#lldb -o 'breakpoint set --name main' -o run $EXE_PATH //starts LLDB, sets a breakpoint at main, and runs the executable.
#libMV_Public.dylib`mv::AbstractHeadsUpDisplayModel::Row::Row(this=..., headsUpDisplayItem=...) at AbstractHeadsUpDisplayModel.h:202:20 //indicates the location in the source code where the function Row of the class mv::AbstractHeadsUpDisplayModel is defined, along with the parameters passed to it.