#!/bin/sh
# In-image self-test: compile, rewrite like the Windows side, run, check versions.
set -eu

if [ "$(id -u)" = 0 ]; then
    exec runuser -u sim -- "$0" "$@"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

printf '%s\n' \
    'module t;' \
    '  initial begin $display("PASS: selftest"); $finish; end' \
    'endmodule' > t.v

# An absolute source path, so the :file_names rewrite has a path to remove.
iverilog -o raw.vvp "$tmp/t.v"

# Same rules as test-remote.ps1 step 2 (README section 5).
awk '
NR == 1 && /^#!/ { next }
/^:vpi_module[ \t]+"/ {
    s = $0
    sub(/^:vpi_module[ \t]+"/, "", s)
    sub(/".*$/, "", s)
    n = split(s, a, /[\/\\]/)
    s = a[n]
    sub(/\.vpi$/, "", s)
    print ":vpi_module \"" s "\";"
    next
}
left > 0 {
    # one entry of the :file_names list per string (each entry is a line "...";)
    out = ""
    rest = $0
    while (match(rest, /"[^"]*"/)) {
        left--
        q = substr(rest, RSTART + 1, RLENGTH - 2)
        n = split(q, a, /[\/\\]/)
        if (q == "N/A") n = 0
        out = out substr(rest, 1, RSTART - 1) "\"" (n ? a[n] : q) "\""
        rest = substr(rest, RSTART + RLENGTH)
    }
    print out rest
    next
}
/^:file_names[ \t]+[0-9]+;/ {
    print
    left = $2 + 0
    next
}
{ print }
' raw.vvp > t.vvp

grep -q "$tmp" raw.vvp || { echo "FAIL: the compiled file has no source path to rewrite" >&2; exit 1; }
if grep -q "$tmp" t.vvp; then echo "FAIL: a source path is left after the rewrite" >&2; exit 1; fi

out="$(vvp -n t.vvp 2>&1)"
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS: selftest$' || { echo "FAIL: no PASS line" >&2; exit 1; }

ver="$(vvp -V 2>&1)"
printf '%s\n' "$ver"
printf '%s\n' "$ver" | grep -q 'version 13\.0' || { echo "FAIL: vvp is not 13.0" >&2; exit 1; }

test -x /usr/lib/openssh/sftp-server || { echo "FAIL: sftp-server missing" >&2; exit 1; }

echo "SELFTEST OK"
