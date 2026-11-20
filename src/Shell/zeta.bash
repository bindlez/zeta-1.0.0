# zeta.bash - the bash half of Zeta.
#
# Sourced by the rcfile Zeta generates for `zeta shell bash`. Renders the same theme as the
# PowerShell prompt from ~/.zeta/theme.bash (generated), and exposes a `zeta` command so the
# framework is not PowerShell-only.
#
# Hot path rule: the prompt must not fork. Segment functions write to REPLY instead of echoing,
# time comes from EPOCHREALTIME / printf %()T, and only git shells out (cached for 2s).

# ---------------------------------------------------------------------------- theme loading

__zeta_theme_load() {
    [ -n "$ZETA_THEME_FILE" ] && [ -f "$ZETA_THEME_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$ZETA_THEME_FILE"
    __zeta_theme_stamp=$(stat -c %Y "$ZETA_THEME_FILE" 2>/dev/null || printf '0')
    ZETA_PROMPT_READY=1
    return 0
}

__zeta_theme_check() {
    [ -n "$ZETA_THEME_FILE" ] || return 0
    local stamp
    stamp=$(stat -c %Y "$ZETA_THEME_FILE" 2>/dev/null || printf '0')
    if [ "$stamp" != "$__zeta_theme_stamp" ]; then
        __zeta_theme_load
    fi
}

# Checking mtime costs a fork, so do it every few prompts rather than every prompt.
__zeta_theme_tick() {
    __zeta_ticks=$(( ${__zeta_ticks:-0} + 1 ))
    if [ $(( __zeta_ticks % 10 )) -eq 0 ]; then
        __zeta_theme_check
    fi
}

# ---------------------------------------------------------------------------- segments

__zeta_seg_dir() {
    local p=$PWD

    # Git Bash can inherit a Windows-style PWD from the parent process; normalise it.
    case "$p" in
        [A-Za-z]:[\\/]*)
            local drive=${p:0:1}
            local rest=${p:2}
            rest=${rest//\\//}
            p="/${drive,}$rest"
            ;;
    esac

    local tilde=0
    if [ -n "$HOME" ] && [ "$p" != "$HOME" ] && [[ $p == "$HOME"/* ]]; then
        p=${p#"$HOME"/}
        tilde=1
    elif [ "$p" = "$HOME" ]; then
        REPLY='~'
        return
    fi

    local IFS='/'
    local -a parts=($p)
    local n=${#parts[@]}
    local out

    if [ "$n" -le 3 ]; then
        out="${parts[*]}"
    else
        out="${parts[n-2]}/${parts[n-1]}"
    fi

    if [ "$tilde" -eq 1 ]; then
        REPLY="$ZETA_GLYPH_FOLDER ~/$out"
    else
        REPLY="$ZETA_GLYPH_FOLDER /$out"
    fi
}

__zeta_seg_git() {
    local now=${EPOCHREALTIME%%.*}
    now=${now//[!0-9]/}

    if [ -n "${__zeta_git_ts:-}" ] && [ $(( now - __zeta_git_ts )) -lt 2 ]; then
        REPLY=$__zeta_git_text
        return
    fi

    local out=''
    if [ -n "$ZETA_CORE" ] && [ -x "$ZETA_CORE" ]; then
        out=$("$ZETA_CORE" git --path "$PWD" 2>/dev/null)
    fi

    local text=''
    if [ -n "$out" ] && [[ $out == OK$'\t'* ]]; then
        local status branch ahead behind staged modified untracked conflict stash detached
        IFS=$'\t' read -r status branch ahead behind staged modified untracked conflict stash detached <<< "$out"
        if [ -n "$branch" ]; then
            text="$ZETA_GLYPH_BRANCH $branch"
            [ "${ahead:-0}" -gt 0 ] 2>/dev/null && text+=" $ZETA_GLYPH_AHEAD$ahead"
            [ "${behind:-0}" -gt 0 ] 2>/dev/null && text+=" $ZETA_GLYPH_BEHIND$behind"
            [ "${staged:-0}" -gt 0 ] 2>/dev/null && text+=" $ZETA_GLYPH_PLUS$staged"
            [ "${modified:-0}" -gt 0 ] 2>/dev/null && text+=" $ZETA_GLYPH_MODIFIED$modified"
            [ "${untracked:-0}" -gt 0 ] 2>/dev/null && text+=" $ZETA_GLYPH_UNTRACKED$untracked"
            [ "${conflict:-0}" -gt 0 ] 2>/dev/null && text+=" $ZETA_GLYPH_CONFLICT$conflict"
        fi
    fi

    __zeta_git_text=$text
    __zeta_git_ts=$now
    REPLY=$text
}

__zeta_seg_venv() {
    [ -n "$VIRTUAL_ENV" ] && REPLY=${VIRTUAL_ENV##*/} || REPLY=''
}

__zeta_seg_status() {
    if [ "${__zeta_exit:-0}" -ne 0 ]; then
        REPLY="$ZETA_GLYPH_CONFLICT ${__zeta_exit}"
    else
        REPLY=''
    fi
}

__zeta_seg_clock() {
    printf -v REPLY '%(%H:%M)T' -1
}

__zeta_seg_duration() {
    if [ "${ZETA_BASH_DURATION:-0}" = "1" ] && [ -n "${__zeta_cmd_start:-}" ] && [ -n "${EPOCHREALTIME:-}" ]; then
        local now=${EPOCHREALTIME/./}
        local start=${__zeta_cmd_start/./}
        local ms=$(( (now - start) / 1000 ))
        if [ "$ms" -ge 100 ]; then
            if [ "$ms" -lt 1000 ]; then REPLY="${ms}ms"; else REPLY=$(awk "BEGIN{printf \"%.2fs\", $ms/1000}"); fi
            return
        fi
    fi
    REPLY=''
}

__zeta_seg_context() {
    if [ -n "${SSH_CONNECTION:-}" ]; then
        REPLY="${USER:-user}@${HOSTNAME%%.*}"
    else
        REPLY=''
    fi
}

# Unknown segment ids are skipped rather than breaking the prompt.
__zeta_segment() {
    REPLY=''
    case "$1" in
        dir) __zeta_seg_dir ;;
        git) __zeta_seg_git ;;
        venv) __zeta_seg_venv ;;
        status) __zeta_seg_status ;;
        clock|time) __zeta_seg_clock ;;
        duration) __zeta_seg_duration ;;
        context) __zeta_seg_context ;;
        *) REPLY='' ;;
    esac
}

# ---------------------------------------------------------------------------- rendering

# Wrap a raw ANSI sequence so readline knows it is zero-width.
__zeta_render() {
    local id=$1
    local text=$2
    local style_var="ZETA_SEG_${id}_STYLE"
    local fg_var="ZETA_SEG_${id}_FG"
    local bg_var="ZETA_SEG_${id}_BG"
    local style=${!style_var}
    local fg=${!fg_var}
    local bg=${!bg_var}
    [ -z "$style" ] && style=plain

    if [ "${ZETA_COLOR:-truecolor}" = "none" ]; then
        REPLY=$text
        return
    fi

    local o='\[' c='\]'
    if [ "$style" = "pill" ] && [ -n "$bg" ]; then
        REPLY="${o}${bg}${c}${o}${fg}${c} ${text} ${o}${ZETA_ANSI_RESET}${c}"
    else
        REPLY="${o}${fg}${c}${text}${o}${ZETA_ANSI_RESET}${c}"
    fi
}

__zeta_build_prompt() {
    local width=${ZETA_WIDTH:-${COLUMNS:-80}}
    local o='\[' c='\]'
    local left='' left_plain='' right='' right_plain=''
    local prev_space=1
    local id text rendered

    for id in $ZETA_LEFT_SEGMENTS; do
        __zeta_segment "$id"
        text=$REPLY
        [ -z "$text" ] && continue
        __zeta_render "$id" "$text"
        rendered=$REPLY

        if [ -n "$left_plain" ] && [ "$prev_space" -eq 0 ]; then
            left+=' '
            left_plain+=' '
        fi
        left+=$rendered
        left_plain+=$text

        local style_var="ZETA_SEG_${id}_STYLE"
        local seg_style=${!style_var}
        if [ "$seg_style" = "pill" ]; then prev_space=1; else prev_space=0; fi
    done

    for id in $ZETA_RIGHT_SEGMENTS; do
        __zeta_segment "$id"
        text=$REPLY
        [ -z "$text" ] && continue
        __zeta_render "$id" "$text"
        if [ -n "$right_plain" ]; then right+='  '; right_plain+='  '; fi
        right+=$REPLY
        right_plain+=$text
    done

    local left_len=$(( ${#left_plain} + 2 ))
    local right_len=${#right_plain}
    local pad=''
    local pad_len=$(( width - left_len - right_len ))

    if [ "${ZETA_COLOR:-truecolor}" = "none" ]; then
        PS1="$ZETA_GLYPH_CORNER$ZETA_GLYPH_DASH $left_plain"
        if [ -n "$right_plain" ] && [ "$pad_len" -gt 0 ]; then
            local pad_plain
            printf -v pad_plain '%*s' "$pad_len" ''
            PS1+="$pad_plain$right_plain"
        fi
        PS1+=$'\n'"$ZETA_GLYPH_CORNEREND$ZETA_GLYPH_DASH$ZETA_GLYPH_PROMPT "
        return
    fi

    local muted="${o}${ZETA_ANSI_MUTED}${c}"
    local accent="${o}${ZETA_ANSI_ACCENT}${c}"
    local reset="${o}${ZETA_ANSI_RESET}${c}"

    if [ "$right_len" -gt 0 ] && [ "$pad_len" -gt 0 ]; then
        printf -v pad '%*s' "$pad_len" ''
    fi

    PS1="${muted}${ZETA_GLYPH_CORNER}${ZETA_GLYPH_DASH}${reset}${left}${pad}${right}"
    PS1+=$'\n'"${muted}${ZETA_GLYPH_CORNEREND}${ZETA_GLYPH_DASH}${reset}${accent}${ZETA_GLYPH_PROMPT}${reset} "
}

__zeta_duration_start() {
    if [ "${ZETA_BASH_DURATION:-0}" = "1" ] && [ -z "${__zeta_in_prompt:-}" ]; then
        __zeta_cmd_start=${EPOCHREALTIME:-}
    fi
}

# ---------------------------------------------------------------------------- frecency jump

__zeta_z_record() {
    [ -n "$ZETA_CORE" ] && [ -x "$ZETA_CORE" ] || return 0
    [ "$PWD" = "${__zeta_last_dir:-}" ] && return 0
    __zeta_last_dir=$PWD
    "$ZETA_CORE" z add --path "$PWD" 2>/dev/null || true
}

z() {
    # Same index as the PowerShell `z`: both shells feed and read one frecency db.
    local arg=${1:-}
    local term=''
    local want_list=0

    case "$arg" in
        '')
            printf 'usage: z <part-of-path> | z -l [term] | z -\n' >&2
            return 2
            ;;
        -l|--list)
            want_list=1
            term=${2:-}
            ;;
        -)
            if [ -n "${OLDPWD:-}" ] && [ -d "$OLDPWD" ]; then cd "$OLDPWD" || return 1; printf '%s\n' "$PWD"; fi
            return 0
            ;;
        *)
            term=$arg
            ;;
    esac

    if [ -z "${ZETA_CORE:-}" ] || [ ! -x "$ZETA_CORE" ]; then
        printf 'z: sensor binary missing (ZETA_CORE)\n' >&2
        return 1
    fi

    if [ "$want_list" = 1 ]; then
        "$ZETA_CORE" z query --term "$term" --limit 10 2>/dev/null |
            while IFS=$'\t' read -r score path; do [ -n "$path" ] && printf '%6.2f  %s\n' "$score" "$path"; done
        return 0
    fi

    local first best
    first=$("$ZETA_CORE" z query --term "$term" --limit 1 2>/dev/null | head -n 1)
    best=${first#*$'\t'}
    if [ -z "$best" ] || [ ! -d "$best" ]; then
        printf 'z: no match for %s\n' "$term" >&2
        return 1
    fi
    cd "$best" || return 1
    printf '%s\n' "$PWD"
}

# ---------------------------------------------------------------------------- prompt hook

__zeta_precmd() {
    local code=$?
    __zeta_in_prompt=1
    __zeta_exit=$code
    __zeta_theme_tick
    __zeta_z_record
    __zeta_build_prompt
    unset __zeta_in_prompt
    __zeta_cmd_start=''
}

__zeta_install_prompt() {
    [ "$ZETA_PROMPT_INSTALLED" = "1" ] && return 0
    case "${PROMPT_COMMAND:-}" in
        *__zeta_precmd*) ;;
        '') PROMPT_COMMAND='__zeta_precmd' ;;
        *) PROMPT_COMMAND="__zeta_precmd; $PROMPT_COMMAND" ;;
    esac
    if [ "${ZETA_BASH_DURATION:-0}" = "1" ]; then
        trap '__zeta_duration_start' DEBUG
    fi
    ZETA_PROMPT_INSTALLED=1
}

# ---------------------------------------------------------------------------- zeta command

__zeta_theme_list() {
    if [ -d "$ZETA_THEMES_DIR" ]; then
        local f
        for f in "$ZETA_THEMES_DIR"/*.json; do
            [ -e "$f" ] || continue
            f=${f##*/}
            printf '  %s\n' "${f%.json}"
        done
    else
        printf '  (themes directory not found: %s)\n' "${ZETA_THEMES_DIR:-unset}"
    fi
}

__zeta_theme_set() {
    local name=$1
    if [ -z "$name" ]; then
        printf 'usage: zeta theme set <name>\n' >&2
        return 2
    fi
    if [ -z "${ZETA_MANIFEST:-}" ]; then
        printf 'zeta: module path unknown (ZETA_MANIFEST unset)\n' >&2
        return 1
    fi
    local ps=${ZETA_POWERSHELL:-powershell.exe}
    "$ps" -NoProfile -Command "Import-Module '$ZETA_MANIFEST' -ErrorAction Stop; Set-ZetaTheme -Name '$name' -Persist | Out-Null" || return $?
    __zeta_theme_load
    printf 'theme: %s\n' "$ZETA_THEME"
}

__zeta_doctor() {
    printf 'zeta %s\n' "${ZETA_VERSION:-?}"
    printf 'bash         : %s\n' "$BASH_VERSION"
    printf 'theme        : %s (%s)\n' "${ZETA_THEME:-unset}" "${ZETA_COLOR:-?}"
    printf 'glyphs       : %s\n' "${ZETA_GLYPHS:-?}"
    printf 'theme file   : %s\n' "$( [ -f "$ZETA_THEME_FILE" ] && printf 'ok' || printf 'MISSING' )"
    printf 'sensor       : %s\n' "$( [ -x "$ZETA_CORE" ] && printf '%s' "$ZETA_CORE" || printf 'not built - git segment will be empty' )"
    printf 'module       : %s\n' "${ZETA_MANIFEST:-unset}"
    printf 'git          : %s\n' "$(command -v git || printf 'missing')"
    printf 'powershell   : %s\n' "${ZETA_POWERSHELL:-missing}"
}

__zeta_shells() {
    printf '%-10s %s\n' 'bash' "(current) $BASH"
    [ -n "${ZETA_POWERSHELL:-}" ] && printf '%-10s %s\n' 'pwsh' "zeta shell ps  (returns to PowerShell in this directory)"
    printf '\nuse: zeta shell ps   |   exit\n'
}

__zeta_inspect() {
    # Dump the real PS1 so a prompt problem can be diagnosed without guessing at a photo.
    local opens closes lines
    opens=$(printf '%s' "$PS1" | grep -o '\\\[' | wc -l)
    closes=$(printf '%s' "$PS1" | grep -o '\\\]' | wc -l)
    lines=$(printf '%s' "$PS1" | wc -l)
    printf 'columns   : %s\n' "${COLUMNS:-unset}"
    printf 'lines     : %s (expect 1 newline)\n' "$lines"
    printf 'chars     : %s\n' "${#PS1}"
    printf 'markers   : %s open / %s close\n' "$opens" "$closes"
    printf 'theme     : %s / %s\n' "${ZETA_THEME:-?}" "${ZETA_COLOR:-?}"
    printf 'segments  : %s | %s\n' "${ZETA_LEFT_SEGMENTS:-}" "${ZETA_RIGHT_SEGMENTS:-}"
    printf 'ps1-escaped:\n%s\n' "$(printf '%s' "$PS1" | cat -v)"
}

__zeta_help() {
    cat <<'EOF'
zeta - bash half of Zeta

  zeta theme list            list themes
  zeta theme set <name>      switch theme (applies to PowerShell and bash)
  zeta theme show            current theme details
  zeta shell ps              leave bash; PowerShell resumes in this directory
  zeta shell inspect         dump PS1 with escapes visible (for bug reports)
  z <part-of-path>           frecency jump (shared with PowerShell)
  z -l [term]                list matches
  z -                        previous directory
  zeta doctor                diagnose the bash side
  zeta version               versions
  exit                       same as `zeta shell ps`

The prompt is generated from the same theme as PowerShell's; changing the theme in either
shell updates the other within a few prompts.
EOF
}

zeta() {
    local cmd=${1:-help}
    shift 2>/dev/null || true
    case "$cmd" in
        theme)
            case "${1:-list}" in
                list) __zeta_theme_list ;;
                set) __zeta_theme_set "${2:-}" ;;
                show)
                    printf 'theme  : %s\ncolor  : %s\nglyphs : %s\n' "${ZETA_THEME:-unset}" "${ZETA_COLOR:-?}" "${ZETA_GLYPHS:-?}"
                    ;;
                *) printf 'usage: zeta theme list|set <name>|show\n' ;;
            esac
            ;;
        shell)
            case "${1:-list}" in
                ps|powershell|pwsh|ps7) printf 'leaving bash...\n'; exit 0 ;;
                bash) printf 'already in bash\n' ;;
                inspect) __zeta_inspect ;;
                *) __zeta_shells ;;
            esac
            ;;
        ps|powershell|pwsh|ps7) printf 'leaving bash...\n'; exit 0 ;;
        doctor) __zeta_doctor ;;
        version) printf 'zeta %s\nbash %s\ncore %s\n' "${ZETA_VERSION:-?}" "$BASH_VERSION" "${ZETA_CORE:-missing}" ;;
        help|--help|-h) __zeta_help ;;
        *) __zeta_help ;;
    esac
}

# ---------------------------------------------------------------------------- boot

if __zeta_theme_load; then
    __zeta_install_prompt
else
    printf 'zeta: theme file missing (%s); run `zeta theme set zeta` in PowerShell\n' "${ZETA_THEME_FILE:-unset}" >&2
fi
