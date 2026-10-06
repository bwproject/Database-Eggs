#!/usr/bin/env bash
# Unit tests for scripts/db-console.sh (no database required).
# A stubbed mysql/mariadb client records the SQL each console command sends.
set -u
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAILED=0
check() { # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '[ok] PASS: %s\n' "$1";
    else FAILED=$((FAILED+1)); printf '[FAIL] %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2; fi
}
contains() { # contains <desc> <needle> <haystack>
    case "$3" in *"$2"*) PASS=$((PASS+1)); printf '[ok] PASS: %s\n' "$1" ;;
    *) FAILED=$((FAILED+1)); printf '[FAIL] %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" >&2 ;; esac
}

echo "== T1: db-console.sh parses and sources cleanly =="
if bash -n scripts/db-console.sh 2>/dev/null; then
    PASS=$((PASS+1)); echo "[ok] PASS: T1 bash -n"
else
    FAILED=$((FAILED+1)); echo "[FAIL] T1 syntax error in scripts/db-console.sh" >&2
fi
if bash -c 'source scripts/db-console.sh >/dev/null 2>&1 && declare -F db_console_handle >/dev/null'; then
    PASS=$((PASS+1)); echo "[ok] PASS: T1 sourcing defines db_console_handle"
else
    FAILED=$((FAILED+1)); echo "[FAIL] T1 sourcing failed or db_console_handle missing" >&2
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export SERVER_DIR="$SANDBOX"
export DB_NAME="appdb"
export DB_ROOT_PASSWORD="rootpw"
export DB_PORT=3306
export STUB_LOG="$SANDBOX/client.log"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/mariadb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
echo "stub-client-ok"
EOF
chmod +x "$SANDBOX/bin/mariadb"
export PATH="$SANDBOX/bin:$PATH"
unset MYSQL_PWD 2>/dev/null || true

source scripts/db-console.sh
exec 3<<< $'promptedpw\npromptedpw'

run() { # run <console line> -> stdout; sets RC
    out="$(db_console_handle "$1" 3)"; RC=$?
}

echo "== T2: help lists account management commands =="
run "help"
contains "T2 user create"   "user create <name> <password> [database]" "$out"
contains "T2 user drop"     "user drop <name>[@host]" "$out"
contains "T2 user password" "user password <name>[@host] <password>" "$out"
contains "T2 grants"        "grants <name>[@host]" "$out"

echo "== T3: user create targets the requested database =="
: > "$STUB_LOG"
run "user create alice Secret1 mydb"
check "T3 rc" "0" "$RC"
sql="$(cat "$STUB_LOG")"
contains "T3 create user" "CREATE USER IF NOT EXISTS 'alice'@'%'" "$sql"
contains "T3 grant"       "GRANT ALL PRIVILEGES ON \`mydb\`.* TO 'alice'@'%'" "$sql"
contains "T3 success msg" "User 'alice'@'%' created on mydb." "$out"

echo "== T4: user create defaults to DB_NAME =="
: > "$STUB_LOG"
run "user create bob Secret2"
contains "T4 default db" "GRANT ALL PRIVILEGES ON \`appdb\`.* TO 'bob'@'%'" "$(cat "$STUB_LOG")"

echo "== T5: user create with explicit host =="
: > "$STUB_LOG"
run "user create carol@10.0.0.5 Secret3 mydb"
contains "T5 host" "CREATE USER IF NOT EXISTS 'carol'@'10.0.0.5'" "$(cat "$STUB_LOG")"
contains "T5 grant keeps db arg" "GRANT ALL PRIVILEGES ON \`mydb\`.* TO 'carol'@'10.0.0.5'" "$(cat "$STUB_LOG")"

echo "== T6: user create prompts on fd 3 when password omitted =="
: > "$STUB_LOG"
run "user create dave"
contains "T6 prompted password" "IDENTIFIED BY 'promptedpw'" "$(cat "$STUB_LOG")"

echo "== T7: user drop =="
: > "$STUB_LOG"
run "user drop bob@localhost"
check "T7 rc" "0" "$RC"
contains "T7 drop sql" "DROP USER IF EXISTS 'bob'@'localhost'" "$(cat "$STUB_LOG")"

echo "== T8: user password =="
: > "$STUB_LOG"
run "user password alice NewSecret"
check "T8 rc" "0" "$RC"
contains "T8 alter sql" "ALTER USER 'alice'@'%' IDENTIFIED BY 'NewSecret'" "$(cat "$STUB_LOG")"

echo "== T9: grants =="
: > "$STUB_LOG"
run "grants alice"
check "T9 rc" "0" "$RC"
contains "T9 show grants" "SHOW GRANTS FOR 'alice'@'%'" "$(cat "$STUB_LOG")"

echo "== T10: users listing still works =="
: > "$STUB_LOG"
run "users"
contains "T10 select mysql.user" "SELECT User,Host FROM mysql.user" "$(cat "$STUB_LOG")"

echo "== T11: invalid account names are rejected before any SQL =="
: > "$STUB_LOG"
run "user create bad;name Secret"
check "T11 rc" "0" "$RC"
contains "T11 message" "Invalid user name" "$out"
check "T11 no SQL sent" "" "$(cat "$STUB_LOG")"
run "user drop bad;name"
contains "T11 drop message" "Invalid user specification" "$out"

echo "== T12: usage errors return 0 (stay inside the console layer) =="
run "user"
check "T12 user usage rc" "0" "$RC"
run "grants"
check "T12 grants usage rc" "0" "$RC"
contains "T12 grants usage text" "Usage: grants" "$out"

echo "== T13: unknown commands return 1 (fall through to watcher log) =="
run "frobnicate"
check "T13 rc" "1" "$RC"

echo "== T14: run.sh sources db-console.sh from the deployed image path =="
contains "T14 run.sh candidates" "/usr/local/bin/db-console.sh" "$(cat run.sh)"
contains "T14 runtime candidate" "/tmp/.database-runtime/db-console.sh" "$(cat run.sh)"

echo "== T15: entrypoint bootstrap downloads db-console.sh =="
bp="$(grep -c 'db-console\.sh' entrypoint.sh)"
check "T15 bootstrap mentions db-console.sh at least twice (curl+wget)" "ok" \
    "$([ "$bp" -ge 2 ] && echo ok || echo "only $bp")"

echo
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
