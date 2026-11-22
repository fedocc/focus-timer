#!/bin/zsh
set -euo pipefail

readonly FOCUS_BUNDLE_ID='local.fedor.focus-menu'
readonly FOCUS_INSTALL_DIRECTORY="${0:A:h}"
readonly FOCUS_SOURCE_APP="$FOCUS_INSTALL_DIRECTORY/Фокус.app"
readonly FOCUS_INSTALL_HELPER="$FOCUS_INSTALL_DIRECTORY/Source/Tools/InstallFocus.js"
readonly FOCUS_TARGET_DIRECTORY="$HOME/Applications"
readonly FOCUS_TARGET_APP="$FOCUS_TARGET_DIRECTORY/Фокус.app"
focus_install_backup=''
focus_install_staging=''
focus_install_committed=0

finish_error() {
    local result=$?
    trap - ZERR
    print -u2 '\nУстановка остановлена.'
    if [[ -n "$focus_install_staging" && -d "$focus_install_staging" ]]; then
        /bin/rm -rf -- "$focus_install_staging"
    fi
    if (( ! focus_install_committed )) && [[ -n "$focus_install_backup" && -d "$focus_install_backup" && ! -e "$FOCUS_TARGET_APP" ]]; then
        /bin/mv -- "$focus_install_backup" "$FOCUS_TARGET_APP"
    fi
    if [[ -t 0 ]]; then
        print 'Нажмите Enter, чтобы закрыть окно.'
        read -r
    fi
    exit "${result:-1}"
}
trap finish_error ZERR

[[ -d "$FOCUS_SOURCE_APP" && -f "$FOCUS_INSTALL_HELPER" ]] || {
    print -u2 'Распакуйте весь архив и запускайте установщик из папки рядом с «Фокус.app».'
    false
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FOCUS_SOURCE_APP/Contents/Info.plist")" == "$FOCUS_BUNDLE_ID" ]]
/usr/bin/codesign --verify --strict "$FOCUS_SOURCE_APP"
/usr/bin/osascript -l JavaScript "$FOCUS_INSTALL_HELPER" preflight

if [[ "${1:-}" == '--check' ]]; then
    /usr/bin/osascript -l JavaScript "$FOCUS_INSTALL_HELPER" running
    print 'Проверка установщика пройдена. Файлы и разрешения не изменялись.'
    exit 0
fi
[[ $# -eq 0 ]]

print 'Закрываем старые копии «Фокуса» обычной командой выхода…'
/usr/bin/osascript -l JavaScript "$FOCUS_INSTALL_HELPER" quit

/bin/mkdir -p "$FOCUS_TARGET_DIRECTORY"
if [[ -e "$FOCUS_TARGET_APP" ]]; then
    [[ -d "$FOCUS_TARGET_APP" && ! -L "$FOCUS_TARGET_APP" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FOCUS_TARGET_APP/Contents/Info.plist")" == "$FOCUS_BUNDLE_ID" ]]
fi

focus_install_staging=$(/usr/bin/mktemp -d "$FOCUS_TARGET_DIRECTORY/.focus-install.XXXXXX")
/usr/bin/ditto "$FOCUS_SOURCE_APP" "$focus_install_staging/Фокус.app"
/usr/bin/codesign --verify --strict "$focus_install_staging/Фокус.app"
/usr/bin/cmp -s "$FOCUS_SOURCE_APP/Contents/MacOS/FocusMenu" "$focus_install_staging/Фокус.app/Contents/MacOS/FocusMenu"
/usr/bin/osascript -l JavaScript "$FOCUS_INSTALL_HELPER" quit

if [[ -e "$FOCUS_TARGET_APP" ]]; then
    focus_install_backup=$(/usr/bin/mktemp -d "$FOCUS_TARGET_DIRECTORY/.focus-previous.XXXXXX")
    /bin/rmdir "$focus_install_backup"
    /bin/mv "$FOCUS_TARGET_APP" "$focus_install_backup"
fi
/bin/mv "$focus_install_staging/Фокус.app" "$FOCUS_TARGET_APP"
/bin/rmdir "$focus_install_staging"
focus_install_staging=''
focus_install_committed=1

# Register the installed copy. App-level control requires no Accessibility permission.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$FOCUS_TARGET_APP"
/usr/bin/osascript -l JavaScript "$FOCUS_INSTALL_HELPER" preflight

print '\nУстановлено: Фокус 1.3'
print "Постоянное место: $FOCUS_TARGET_APP"
if [[ -n "$focus_install_backup" ]]; then
    print "Предыдущая установленная копия сохранена: $focus_install_backup"
fi
print '\nВ Finder будет выделена именно установленная копия.'
print 'Универсальный доступ больше не требуется.'

/usr/bin/open -a "$FOCUS_TARGET_APP"
/usr/bin/osascript -l JavaScript "$FOCUS_INSTALL_HELPER" reveal "$FOCUS_TARGET_APP"
if [[ -t 0 ]]; then
    print '\nНажмите Enter, чтобы закрыть это окно.'
    read -r
fi
