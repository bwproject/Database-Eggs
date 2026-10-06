#!/bin/bash
DB_PORT="${SERVER_PORT:-3306}"

_dbcli(){
  command -v mariadb >/dev/null 2>&1 && echo mariadb || echo mysql
}

# Escape a value for use inside a single-quoted SQL string literal.
_db_esc(){
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf '%s' "$s"
}

# Accept "name" or "name@host" -> sets _db_user and _db_host (host defaults to %).
_db_split_user(){
  local spec="$1"
  if [[ "$spec" == *@* ]]; then
    _db_user="${spec%%@*}"
    _db_host="${spec#*@}"
  else
    _db_user="$spec"
    _db_host="%"
  fi
  [[ "$_db_user" =~ ^[A-Za-z0-9_.$]+$ ]] || return 1
  [[ "$_db_host" =~ ^[A-Za-z0-9_.%-]+$ ]] || return 1
}

_db_sql_session(){
  local fd="${1:-3}" c="${2:-$(_dbcli)}"
  shift 2 || true
  local -a args=("$@")
  local line

  echo "MySQL interactive console mode."
  echo "Enter SQL commands normally. Type 'exit' or 'quit' to leave."
  echo "Example: SHOW DATABASES;"

  while IFS= read -r -u "$fd" line; do
    line="${line//$'\r'/}"
    [ -n "$line" ] || continue

    case "${line,,}" in
      exit|quit|'exit;'|'quit;'|EXIT|QUIT|'EXIT;'|'QUIT;')
        echo "Interactive console closed."
        return 0
        ;;
      *)
        MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" "${args[@]}" --table -e "$line"
        ;;
    esac
  done

  echo "Interactive console closed."
}

db_console_handle(){
  local line="$1" fd="${2:-3}" cmd rest db file out c
  line="${line//$'\r'/}"
  cmd="${line%%[[:space:]]*}"
  rest="${line#"$cmd"}"
  rest="${rest#${rest%%[![:space:]]*}}"

  case "${cmd,,}" in
    help)
      printf '%s\n' \
        'help' 'status' 'version' 'databases' 'users' \
        'user create <name> <password> [database]' \
        'user drop <name>[@host]' \
        'user password <name>[@host] <password>' \
        'grants <name>[@host]' \
        'dump' 'dump <database>' 'dump create [database]' \
        'restore <file>' 'dump restore <file>' \
        'sql <SQL>' 'sql' 'root' 'root <new_password>' \
        'mysql [mysql arguments]' 'mariadb [mariadb arguments]'
      ;;

    status)
      c=$(_dbcli)
      MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -Nse 'SELECT 1' >/dev/null 2>&1 \
        && echo "${PROJECT_TYPE^^} status: ONLINE" \
        || echo "${PROJECT_TYPE^^} status: OFFLINE"
      ;;

    version)
      c=$(_dbcli)
      MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -Nse 'SELECT VERSION();'
      ;;

    databases)
      c=$(_dbcli)
      MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e 'SHOW DATABASES;'
      ;;

    users)
      c=$(_dbcli)
      MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e 'SELECT User,Host FROM mysql.user ORDER BY User,Host;'
      ;;

    # Account management. mysql.user is a read-only compatibility VIEW in
    # MariaDB >= 10.4 (it projects mysql.global_priv), so accounts must be
    # managed with CREATE/ALTER/DROP USER statements, not table edits.
    user)
      local sub="${rest%%[[:space:]]*}"
      local tail="${rest#"$sub"}"
      tail="${tail#${tail%%[![:space:]]*}}"
      case "${sub,,}" in
        create)
          local uname="${tail%%[[:space:]]*}"
          local after="${tail#"$uname"}"
          after="${after#${after%%[![:space:]]*}}"
          local upass="${after%%[[:space:]]*}"
          local udb="${after#"$upass"}"
          udb="${udb# }"
          [ -n "$uname" ] || { echo "Usage: user create <name> <password> [database]"; return 0; }
          if [ -z "$upass" ]; then
            printf 'Password for %s: ' "$uname"
            IFS= read -r -s upass <&"$fd" || return 0
            printf '\n'
          fi
          _db_split_user "$uname" || { echo "Invalid user name or host (allowed: letters, digits, _ . \$ - %)"; return 0; }
          uname="$_db_user"; local host="$_db_host"
          [ -n "$udb" ] || udb="$DB_NAME"
          if [ -n "$udb" ] && ! [[ "$udb" =~ ^[A-Za-z0-9_.$-]+$ ]]; then
            echo "Invalid database name '${udb}' (allowed: letters, digits, _ . \$ -)."
            return 0
          fi
          c=$(_dbcli)
          local esc_name esc_host esc_pass q esc_db
          esc_name="$(_db_esc "$uname")"; esc_host="$(_db_esc "$host")"; esc_pass="$(_db_esc "$upass")"
          if [ -n "$udb" ]; then
            esc_db="$(_db_esc "$udb")"
            q="CREATE USER IF NOT EXISTS '${esc_name}'@'${esc_host}' IDENTIFIED BY '${esc_pass}'; GRANT ALL PRIVILEGES ON \`${esc_db}\`.* TO '${esc_name}'@'${esc_host}'; FLUSH PRIVILEGES;"
          else
            q="CREATE USER IF NOT EXISTS '${esc_name}'@'${esc_host}' IDENTIFIED BY '${esc_pass}'; GRANT ALL PRIVILEGES ON *.* TO '${esc_name}'@'${esc_host}' WITH GRANT OPTION; FLUSH PRIVILEGES;"
            echo "No database given (DB_NAME unset): granting privileges on *.*."
          fi
          if MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e "$q"; then
            echo "User '${uname}'@'${host}' created on ${udb:-*.*}."
          else
            echo "Failed to create user '${uname}'@'${host}'."
          fi
          ;;
        drop|remove|delete)
          [ -n "$tail" ] || { echo "Usage: user drop <name>[@host]"; return 0; }
          _db_split_user "$tail" || { echo "Invalid user specification."; return 0; }
          c=$(_dbcli)
          if MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e \
            "DROP USER IF EXISTS '${_db_user}'@'${_db_host}'; FLUSH PRIVILEGES;"; then
            echo "User '${_db_user}'@'${_db_host}' dropped."
          else
            echo "Failed to drop user '${_db_user}'@'${_db_host}'."
          fi
          ;;
        password|passwd)
          local uspec="${tail%%[[:space:]]*}"
          local rest2="${tail#"$uspec"}"
          rest2="${rest2#${rest2%%[![:space:]]*}}"
          local npass="${rest2%%[[:space:]]*}"
          [ -n "$uspec" ] || { echo "Usage: user password <name>[@host] <password>"; return 0; }
          if [ -z "$npass" ]; then
            printf 'New password for %s: ' "$uspec"
            IFS= read -r -s npass <&"$fd" || return 0
            printf '\nConfirm password: '
            local npass2
            IFS= read -r -s npass2 <&"$fd" || return 0
            printf '\n'
            [ "$npass" = "$npass2" ] || { echo 'Passwords do not match.'; return 0; }
          fi
          _db_split_user "$uspec" || { echo "Invalid user specification."; return 0; }
          c=$(_dbcli)
          if MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e \
            "ALTER USER '${_db_user}'@'${_db_host}' IDENTIFIED BY '$(_db_esc "$npass")'; FLUSH PRIVILEGES;"; then
            echo "Password changed for '${_db_user}'@'${_db_host}'."
          else
            echo "Failed to change password for '${_db_user}'@'${_db_host}' (user may not exist)."
          fi
          ;;
        *)
          echo "Usage: user create <name> <password> [database] | user drop <name>[@host] | user password <name>[@host] <password>"
          ;;
      esac
      ;;

    grants)
      [ -n "$rest" ] || { echo "Usage: grants <name>[@host]   (see 'users' for the account list)"; return 0; }
      _db_split_user "$rest" || { echo "Invalid user specification."; return 0; }
      c=$(_dbcli)
      MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e \
        "SHOW GRANTS FOR '${_db_user}'@'${_db_host}';" \
        || echo "No grants found for '${_db_user}'@'${_db_host}' (account may not exist)."
      ;;

    dump)
      if [[ "$rest" == restore\ * ]]; then
        file="${rest#restore }"
        db="$DB_NAME"
        [ -f "$file" ] || file="$SERVER_DIR/$file"
        [ -f "$file" ] || { echo "File not found: $file"; return 0; }
        c=$(_dbcli)
        echo "Restoring $file into $db..."
        if [[ "$file" == *.gz ]]; then
          gzip -dc "$file" | MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root "$db"
        else
          MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root "$db" < "$file"
        fi
        return 0
      fi

      [[ "$rest" == create\ * ]] && rest="${rest#create }"
      db="${rest:-$DB_NAME}"
      mkdir -p "$SERVER_DIR/dumps"
      out="$SERVER_DIR/dumps/$db-$(date -u +%Y-%m-%d_%H-%M-%S).sql.gz"
      c=$(_dbcli)
      echo "Creating dump: $db"

      if command -v mariadb-dump >/dev/null 2>&1; then
        MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb-dump --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root \
          --single-transaction --routines --events --triggers "$db" | gzip -c > "$out"
      else
        MYSQL_PWD="$DB_ROOT_PASSWORD" mysqldump --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root \
          --single-transaction --routines --events --triggers "$db" | gzip -c > "$out"
      fi

      if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$out" ]; then
        echo "Dump completed: $out"
      else
        rm -f "$out"
        echo "Dump failed."
      fi
      ;;

    restore)
      [[ "$rest" == dump\ * ]] && rest="${rest#dump }"
      file="${rest%% *}"
      db="${rest#"$file"}"
      db="${db# }"
      [ -n "$db" ] || db="$DB_NAME"
      [ -f "$file" ] || file="$SERVER_DIR/$file"
      [ -f "$file" ] || { echo "File not found: $rest"; return 0; }

      c=$(_dbcli)
      echo "Restoring $file into $db..."
      if [[ "$file" == *.gz ]]; then
        gzip -dc "$file" | MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root "$db"
      else
        MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root "$db" < "$file"
      fi
      echo 'Restore completed.'
      ;;

    sql)
      c=$(_dbcli)
      if [ -n "$rest" ]; then
        MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e "$rest"
      else
        _db_sql_session "$fd" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root
      fi
      ;;

    root)
      local new="$rest"
      if [ -z "$new" ]; then
        printf 'New root password: '
        IFS= read -r -s new <&"$fd" || return 0
        printf '\nConfirm root password: '
        local confirm
        IFS= read -r -s confirm <&"$fd" || return 0
        printf '\n'
        [ "$new" = "$confirm" ] || { echo 'Passwords do not match.'; return 0; }
      fi

      c=$(_dbcli)
      local q
      q=$(printf '%s' "$new" | sed "s/'/''/g")

      MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" --protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root -e \
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '$q'; ALTER USER IF EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$q'; FLUSH PRIVILEGES;" \
        && {
          DB_ROOT_PASSWORD="$new"
          export DB_ROOT_PASSWORD
          declare -F pf_users_store_root >/dev/null 2>&1 && pf_users_store_root "$new"

          if [ -f "$SERVER_DIR/.env" ]; then
            if grep -q '^DB_ROOT_PASSWORD=' "$SERVER_DIR/.env"; then
              sed -i "s|^DB_ROOT_PASSWORD=.*$|DB_ROOT_PASSWORD=$new|" "$SERVER_DIR/.env"
            else
              printf '\nDB_ROOT_PASSWORD=%s\n' "$new" >> "$SERVER_DIR/.env"
            fi
            chmod 600 "$SERVER_DIR/.env" 2>/dev/null || true
          fi

          echo 'Root password successfully changed.'
        }
      ;;

    mysql|mariadb)
      # Pterodactyl/Wings sends console commands as lines to container STDIN.
      # A real interactive mysql client expects a terminal, so use a persistent
      # SQL session driven by subsequent console lines instead.
      read -r -a argv <<< "$line"
      unset 'argv[0]'
      c=$(_dbcli)

      local execute_sql="" i=0 a next
      local -a args=(--protocol=tcp -h 127.0.0.1 -P "$DB_PORT" -u root)

      while [ "$i" -lt "${#argv[@]}" ]; do
        a="${argv[$i]}"
        case "$a" in
          -e|--execute)
            i=$((i + 1))
            execute_sql="${argv[$i]:-}"
            ;;
          --execute=*)
            execute_sql="${a#--execute=}"
            ;;
          -p|--password|-p*|--password=*)
            ;;
          -u|--user)
            i=$((i + 1))
            next="${argv[$i]:-}"
            [ "$next" = "root" ] || echo "Console authentication is fixed to root; requested user '$next' was ignored."
            ;;
          -h|--host|-P|--port|-D|--database)
            i=$((i + 1))
            args+=( "$a" "${argv[$i]:-}" )
            ;;
          --host=*|--port=*|--database=*)
            args+=( "${a%%=*}" "${a#*=}" )
            ;;
          --user=*)
            next="${a#--user=}"
            [ "$next" = "root" ] || echo "Console authentication is fixed to root; requested user '$next' was ignored."
            ;;
          *)
            args+=( "$a" )
            ;;
        esac
        i=$((i + 1))
      done

      if [ -n "$execute_sql" ]; then
        MYSQL_PWD="$DB_ROOT_PASSWORD" "$c" "${args[@]}" -e "$execute_sql"
      else
        _db_sql_session "$fd" "$c" "${args[@]}"
      fi
      ;;

    *)
      return 1
      ;;
  esac

  return 0
}
