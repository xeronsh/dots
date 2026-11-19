# Home Manager supplies session paths, variables and Starship.

# NixOS has one compositor in this configuration, unlike the old Arch switcher.
function switch-wm --description 'Start the configured compositor'
    niri-session $argv
end

function ccat --description 'Copy file contents to the clipboard'
    if test (count $argv) -ne 1
        echo '用法: ccat <文件>'
        return 1
    end
    if not test -f "$argv[1]"
        echo "文件不存在: $argv[1]"
        return 1
    end
    fish_clipboard_copy < "$argv[1]"
end

