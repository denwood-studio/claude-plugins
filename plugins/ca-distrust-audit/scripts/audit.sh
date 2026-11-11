#!/usr/bin/env bash
set -u

USER_PATH=${PATH-}
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$USER_PATH
export PATH
export LC_ALL=C

TAB=$(printf '\t')
NL=$'\n'

AWK_LIB='
function ord_init(   i) { for (i = 32; i < 127; i++) ORD[sprintf("%c", i)] = i }
function isdig(c) { return c ~ /^[0-9]$/ }
function vord(c) {
  if (c == "" || isdig(c)) return 0
  if (c ~ /^[A-Za-z]$/) return ORD[c]
  if (c == "~") return -1
  return ORD[c] + 256
}
function vercmp(a, b,   i, j, la, lb, fd, ac, bc) {
  sub(/^v/, "", a); sub(/^v/, "", b)
  la = length(a); lb = length(b); i = 1; j = 1
  while (i <= la || j <= lb) {
    fd = 0
    while ((i <= la && !isdig(substr(a, i, 1))) || (j <= lb && !isdig(substr(b, j, 1)))) {
      ac = vord(substr(a, i, 1)); bc = vord(substr(b, j, 1))
      if (ac != bc) return ac - bc
      i++; j++
    }
    while (substr(a, i, 1) == "0") i++
    while (substr(b, j, 1) == "0") j++
    while (isdig(substr(a, i, 1)) && isdig(substr(b, j, 1))) {
      if (!fd) fd = substr(a, i, 1) - substr(b, j, 1)
      i++; j++
    }
    if (isdig(substr(a, i, 1))) return 1
    if (isdig(substr(b, j, 1))) return -1
    if (fd) return fd
  }
  return 0
}
function lineof(c, v,   re) {
  sub(/^v/, "", v)
  re = (c in LINERE) ? LINERE[c] : "^[0-9]+"
  if (match(v, re)) return substr(v, RSTART, RLENGTH)
  return ""
}
function load(file,   ln, a) {
  while ((getline ln < file) > 0) {
    sub(/\r$/, "", ln)
    if (ln ~ /^[ \t]*#/ || ln ~ /^[ \t]*$/) continue
    split(ln, a, "\t")
    if (a[1] == "event") EVENT = a[2]
    else if (a[1] == "as-of") ASOF = a[2]
    else if (a[1] == "source") { if (!NSRC++) SRC1 = a[2] }
    else if (a[1] == "cert") { CERT[toupper(a[2])] = a[3]; NCERT++ }
    else if (a[1] == "fixed") { NFIX[a[2]]++; FIX[a[2], NFIX[a[2]]] = a[3] }
    else if (a[1] == "line") LINERE[a[2]] = a[3]
  }
  close(file)
}
function assess(c, v,   k, F, lv, on, best, max) {
  lv = lineof(c, v); on = 0; best = ""
  for (k = 1; k <= NFIX[c]; k++) {
    F = FIX[c, k]
    if (lineof(c, F) == lv) {
      if (vercmp(v, F) >= 0) { RES = "ok"; RESW = "line"; RESF = F; return }
      if (best == "" || vercmp(F, best) < 0) best = F
      on = 1
    }
  }
  if (on) { RES = "move"; RESF = best; return }
  max = ""; best = ""
  for (k = 1; k <= NFIX[c]; k++) {
    F = FIX[c, k]
    if (max == "" || vercmp(F, max) > 0) max = F
    if (vercmp(F, v) > 0 && (best == "" || vercmp(F, best) < 0)) best = F
  }
  if (best == "") { RES = "ok"; RESW = "newer"; RESF = max; return }
  RES = "move"; RESF = best
}
function fixedlist(c,   k, s) {
  s = ""
  for (k = 1; k <= NFIX[c]; k++) s = s (k > 1 ? ", " : "") FIX[c, k]
  return s
}
function isort(arr, n,   i, j, t) {
  for (i = 2; i <= n; i++) {
    t = arr[i]; j = i - 1
    while (j >= 1 && (arr[j] "") > (t "")) { arr[j + 1] = arr[j]; j-- }
    arr[j + 1] = t
  }
}
'

AWK_META='
BEGIN {
  load(ENVIRON["CA_DATAFILE"]); w = ENVIRON["CA_WHAT"]
  if (w == "event") print EVENT
  else if (w == "asof") print ASOF
  else if (w == "source") print SRC1
  else if (w == "ncert") print NCERT + 0
  else if (w == "npkg") print NFIX["dpkg:ca-certificates"] + NFIX["apk:ca-certificates"]
}
'

AWK_VCHECK='
BEGIN {
  ord_init(); load(ENVIRON["CA_DATAFILE"])
  c = ENVIRON["CA_COMP"]; v = ENVIRON["CA_VER"]
  if (NFIX[c] == 0) { print "none"; exit }
  assess(c, v)
  if (RES == "ok") print "ok\t" RESW "\t" RESF
  else print "move\t" RESF
}
'

AWK_SORT='
BEGIN { FS = "\t" }
{
  k = $1; t = substr($0, length(k) + 2)
  if (!(k in C)) { nk++; K[nk] = k }
  C[k]++; T[k, C[k]] = t
}
function isort(arr, n,   i, j, t) {
  for (i = 2; i <= n; i++) {
    t = arr[i]; j = i - 1
    while (j >= 1 && (arr[j] "") > (t "")) { arr[j + 1] = arr[j]; j-- }
    arr[j + 1] = t
  }
}
END {
  isort(K, nk)
  for (i = 1; i <= nk; i++) for (j = 1; j <= C[K[i]]; j++) print T[K[i], j]
}
'

AWK_DOCKER='
BEGIN {
  ord_init(); load(ENVIRON["CA_DATAFILE"])
  ROOT = ENVIRON["CA_ROOT"]; PFX = (ROOT == "/") ? "/" : ROOT "/"
  Q = "\047"; ARGCH = "[^ \t\"" Q ";&|)]+"
  DPKG_RE = "dpkg[ \t]+--compare-versions[ \t][^;&|]*ca-certificates[^;&|]*[ \t](ge|gt|eq)[ \t]+[\"" Q "]?" ARGCH
  APT_RE = "(^|[^A-Za-z0-9_-])apt(-get)?[ \t][^;&|]*ca-certificates=" ARGCH
  APK_RE = "(^|[^A-Za-z0-9_-])apk[ \t][^;&|]*ca-certificates(>=|=)" ARGCH
  INST_RE = "(^|[^A-Za-z0-9_-])(apt|apt-get|aptitude|apk|dnf|yum|microdnf|tdnf|zypper)[ \t]([^;&|]*[ \t])?(install|reinstall|add|upgrade|dist-upgrade|full-upgrade|--only-upgrade)[ \t][^;&|]*ca-certificates"
  INST2_RE = "(^|[^A-Za-z0-9_-])(dnf|yum|microdnf|tdnf)[ \t]([^;&|]*[ \t])?(update|distro-sync)[ \t][^;&|]*ca-certificates"
  UP_RE = "(^|[^A-Za-z0-9_-])((apt|apt-get|aptitude)[ \t]([^;&|]*[ \t])?(upgrade|dist-upgrade|full-upgrade|safe-upgrade)|apk[ \t]([^;&|]*[ \t])?upgrade|(dnf|yum|microdnf|tdnf)[ \t]([^;&|]*[ \t])?(upgrade|update|distro-sync))([ \t;&|]|$)"
  RPM_RE = "(^|[/:._-])(ubi|rhel|redhat|centos|fedora|rockylinux|almalinux|amazonlinux|oraclelinux|opensuse|suse|sles|bci|photon|azurelinux|mariner)[0-9]*([/:._-]|$)"
}
function relname(   r) {
  r = CUR
  if (index(r, PFX) == 1) r = substr(r, length(PFX) + 1)
  gsub(/[^ -~]/, "?", r)
  return r
}
function family(img,   l) {
  l = tolower(img)
  return (l ~ /alpine|wolfi|chainguard/) ? "apk:ca-certificates" : "dpkg:ca-certificates"
}
function isrpm(img) { return tolower(img) ~ RPM_RE }
function showimg(img) {
  gsub(/[^ -~]/, "?", img)
  if (length(img) > 80) img = substr(img, 1, 80) "..."
  return img
}
function proof(c, v) {
  if (v !~ /^[0-9][A-Za-z0-9.+~:_-]*$/ || NFIX[c] == 0) return
  assess(c, v)
  if (RES == "ok" && SPROOF[ns] == "") SPROOF[ns] = v
}
function handle(ln,   t, n, k, w, lc, i, s, m) {
  sub(/^[ \t]+/, "", ln)
  n = split(ln, t, /[ \t]+/)
  w = toupper(t[1])
  if (w == "FROM") {
    k = 2
    while (k <= n && t[k] ~ /^--/) k++
    if (k > n) return
    ns++
    SIMG[ns] = t[k]; SNAME[ns] = ""; SPAR[ns] = 0; SPROOF[ns] = ""; SINST[ns] = 0
    if (k + 2 <= n && toupper(t[k + 1]) == "AS") SNAME[ns] = tolower(t[k + 2])
    lc = tolower(t[k])
    for (i = ns - 1; i >= 1; i--) if (SNAME[i] != "" && SNAME[i] == lc) { SPAR[ns] = i; break }
    if (SPAR[ns]) { SSCR[ns] = SSCR[SPAR[ns]]; RIMG[ns] = RIMG[SPAR[ns]] }
    else { SSCR[ns] = (lc == "scratch"); RIMG[ns] = t[k] }
    return
  }
  if (!ns) return
  if (w ~ /^(CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|STOPSIGNAL|HEALTHCHECK|SHELL|ONBUILD)$/) return
  if (w == "RUN" && ln ~ /^[^ \t]+[ \t]+\[/) gsub(/\[|\]|"|,/, " ", ln)
  s = ln
  while (match(s, DPKG_RE)) {
    m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(".*[ \t][\"" Q "]?", "", m); proof("dpkg:ca-certificates", m)
  }
  s = ln
  while (match(s, APT_RE)) {
    m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/.*=/, "", m); proof("dpkg:ca-certificates", m)
  }
  s = ln
  while (match(s, APK_RE)) {
    m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/.*=/, "", m); proof("apk:ca-certificates", m)
  }
  if (ln ~ INST_RE || ln ~ INST2_RE || ln ~ UP_RE) SINST[ns] = 1
}
function own(i) { if (SPROOF[i] != "") return 2; if (SINST[i]) return 1; return 0 }
function flush(   i, p, b, q, worst, anyass, anyscr, anyrpm, rel, f, img, doneimg, pv, npv, seenpv, txt) {
  if (!ns) return
  rel = relname()
  print rel "\t@seen"
  worst = 9; anyass = 0; anyscr = 0; anyrpm = 0; doneimg = ""
  for (i = 1; i <= ns; i++) {
    ST[i] = -1
    if (SSCR[i]) { anyscr = 1; continue }
    if (isrpm(RIMG[i])) {
      anyrpm = 1
      img = showimg(SIMG[i])
      if (SPAR[i] == 0 && index(doneimg, "|" img "|") == 0) {
        doneimg = doneimg "|" img "|"
        print rel "\tNOT ASSESSED " rel ": stage FROM " img " is an RPM-family image, and the fixed ca-certificates versions here are for Debian, Ubuntu and Alpine — check your image vendor\047s advisory, or the built image with: docker run --rm <your-image> rpm -q ca-certificates"
      }
      continue
    }
    if (NFIX[family(RIMG[i])] == 0) continue
    b = own(i); p = SPAR[i]
    while (p) { q = own(p); if (q > b) b = q; p = SPAR[p] }
    ST[i] = b; anyass = 1
    if (SPAR[i] == 0 && b < worst) worst = b
  }
  if (!anyass) {
    if (anyscr && !anyrpm) print rel "\tNOT ASSESSED " rel ": every stage is built FROM scratch, so there is no base image trust store to assess"
    return
  }
  if (worst == 2) {
    txt = ""; npv = 0; doneimg = ""
    for (i = 1; i <= ns; i++) {
      if (SPAR[i] != 0 || ST[i] != 2) continue
      if (index(doneimg, "|" SPROOF[i] "|") == 0) { doneimg = doneimg "|" SPROOF[i] "|"; txt = txt (npv++ ? ", " : "") SPROOF[i] }
    }
    print rel "\tCLEAR " rel ": ca-certificates is asserted at a fixed version (" txt ")" (anyrpm ? "; stages built on an RPM-family image are not assessed" : "")
    return
  }
  doneimg = ""
  for (i = 1; i <= ns; i++) {
    if (SPAR[i] != 0 || ST[i] != worst) continue
    img = showimg(SIMG[i])
    if (index(doneimg, "|" img "|") > 0) continue
    doneimg = doneimg "|" img "|"
    f = family(SIMG[i])
    if (worst == 0)
      print rel "\tFLAG " rel ": stage FROM " img " neither installs, upgrades nor version-checks ca-certificates — move to ca-certificates " fixedlist(f) " (the entry for your base image release)"
    else if (f == "apk:ca-certificates")
      print rel "\tUNCONFIRMED " rel ": stage FROM " img " installs or upgrades ca-certificates without asserting a fixed version, and a cached layer keeps an old store — confirm the built image with: docker run --rm <your-image> apk info -v ca-certificates (fixed: " fixedlist(f) ")"
    else
      print rel "\tUNCONFIRMED " rel ": stage FROM " img " installs or upgrades ca-certificates without asserting a fixed version, and a cached layer keeps an old store — confirm the built image with: docker run --rm <your-image> dpkg-query -W ca-certificates (fixed: " fixedlist(f) ")"
  }
}
function endfile() {
  if (cont) handle(buf)
  cont = 0; buf = ""
  flush()
  ns = 0
}
FNR == 1 { if (NR > 1) endfile(); CUR = FILENAME }
{
  sub(/\r$/, "")
  if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next
  if (cont) buf = buf " " $0; else buf = $0
  if (buf ~ /\\[ \t]*$/) { sub(/[ \t]*\\[ \t]*$/, "", buf); cont = 1; next }
  cont = 0; handle(buf); buf = ""
}
END { endfile() }
'

AWK_PEM_EXTRACT='
BEGIN {
  ROOT = ENVIRON["CA_ROOT"]; PFX = (ROOT == "/") ? "/" : ROOT "/"
  B = "-----BEGIN CERTIFICATE-----"; E = "-----END CERTIFICATE-----"
  rc = ""; bad = 0
}
function emit(f,   r, b) {
  b = body; gsub("[^A-Za-z0-9+/=]", "", b)
  if (b == "") return
  r = f
  if (index(r, PFX) == 1) r = substr(r, length(PFX) + 1)
  gsub(/[^ -~]/, "?", r)
  print r "\t" b
}
function scan(f,   ln, p, r) {
  inb = 0; body = ""
  while ((r = (getline ln < f)) > 0) {
    if (!inb && index(ln, B) == 0) continue
    gsub(/\\[nrt]/, " ", ln); gsub(/\r/, "", ln)
    while (length(ln) > 0) {
      if (!inb) {
        p = index(ln, B)
        if (!p) break
        ln = substr(ln, p + length(B)); inb = 1; body = ""
      } else {
        p = index(ln, E)
        if (p) { body = body substr(ln, 1, p - 1); ln = substr(ln, p + length(E)); inb = 0; emit(f) }
        else { body = body ln; ln = "" }
      }
    }
  }
  if (r < 0) bad++
  close(f)
}
/^@rc / { rc = substr($0, 5); next }
$0 != "" { scan($0) }
END {
  if (rc == "") rc = 1
  print "@rc " (rc + bad)
}
'

AWK_PEM_MATCH='
BEGIN { ord_init(); load(ENVIRON["CA_DATAFILE"]); FS = "\t" }
$1 != "" {
  rel = $1; h = toupper($2)
  if (!(rel in SEEN)) { SEEN[rel] = 1; nfile++; R[nfile] = rel }
  if (length(h) == 64 && h ~ /^[0-9A-F]+$/ && (h in CERT)) {
    lab = CERT[h]; k = rel SUBSEP lab
    if (!(k in LS)) { LS[k] = 1; NLAB[rel]++; L[rel, NLAB[rel]] = lab }
  }
}
END {
  isort(R, nfile); flagged = 0
  for (i = 1; i <= nfile; i++) {
    r = R[i]
    if (NLAB[r] > 0) {
      flagged++; s = ""
      for (j = 1; j <= NLAB[r] && j <= 3; j++) s = s (j > 1 ? ", " : "") L[r, j]
      if (NLAB[r] > 3) s = s " and " (NLAB[r] - 3) " more"
      print "FLAG " r ": contains " s "; replace the bundle or point the library at the system store"
    }
  }
  if (!flagged && ENVIRON["CA_SCAN_RC"] == "0") {
    if (nfile == 0) print "CLEAR certificate bundles: no PEM files found"
    else print "CLEAR certificate bundles: " nfile " PEM file(s) scanned, none contains a listed certificate"
  }
}
'

NOT_CHECKED_MACHINE="Homebrew/Python/pip/certifi stores; Java keystores; Go/Rust binaries; Docker Desktop and images; browsers; apps outside /Applications and ~/Applications; apps that patch their own store"
NOT_CHECKED_REPO_HEAD="lockfiles and version pins; images pulled by name (compose files, CI); runtimes inside images; RPM-family base images (UBI, RHEL, CentOS, Fedora, Rocky, Alma, Amazon Linux, Oracle Linux, SUSE)"
NOT_CHECKED_REPO_TAIL="the live TLS behaviour of built images"

REPORT_FLAG=0
REPORT_UNC=0

usage() {
  echo "usage: audit.sh machine | audit.sh repo <dir>" >&2
  exit 2
}

fail() {
  echo "audit.sh: $1" >&2
  exit 2
}

clean() { printf '%s' "$1" | tr -c ' -~' '?'; }

emit() {
  printf '%s\n' "$1"
  case $1 in
    FLAG\ *) REPORT_FLAG=1 ;;
    UNCONFIRMED\ *) REPORT_UNC=1 ;;
  esac
}

emit_lines() {
  local IFS=$NL l
  set -f
  for l in $1; do emit "$l"; done
  set +f
}

abspath() {
  local p=$1 part out="" i=0 n=0
  local -a stack=()
  case $p in
    /*) ;;
    *) p=$PWD/$p ;;
  esac
  local IFS=/
  set -f
  for part in $p; do
    case $part in
      '' | .) ;;
      ..) if [ "$n" -gt 0 ]; then n=$((n - 1)); unset "stack[$n]"; fi ;;
      *) stack[$n]=$part; n=$((n + 1)) ;;
    esac
  done
  set +f
  while [ "$i" -lt "$n" ]; do out="$out/${stack[$i]}"; i=$((i + 1)); done
  [ -n "$out" ] || out=/
  printf '%s\n' "$out"
}

meta_get() { CA_DATAFILE=$1 CA_WHAT=$2 awk "$AWK_LIB$AWK_META"; }

vcheck() { CA_DATAFILE=$1 CA_COMP=$2 CA_VER=$3 awk "$AWK_LIB$AWK_VCHECK"; }

check_version() {
  local f=$1 comp=$2 subject=$3 what=$4 ver=$5 res kind rest sub fixed
  res=$(vcheck "$f" "$comp" "$ver")
  ver=${ver#v}
  kind=${res%%$TAB*}
  [ "$kind" = none ] && return 0
  rest=${res#*$TAB}
  subject=$(clean "$subject")
  if [ "$kind" = ok ]; then
    sub=${rest%%$TAB*}
    fixed=${rest#*$TAB}
    if [ "$sub" = line ]; then
      emit "CLEAR $subject: $what $ver meets the fixed release $fixed"
    else
      emit "CLEAR $subject: $what $ver is newer than every fixed release (newest $fixed)"
    fi
    return 0
  fi
  case $comp in
    electron) emit "FLAG $subject: $what $ver predates the fixed release — update $subject to a release built on Electron ≥ $rest" ;;
    *) emit "FLAG $subject: $what $ver predates the fixed release — move to $rest" ;;
  esac
}

resolve_path() {
  local f=$1 n=0 t d
  while [ -L "$f" ] && [ "$n" -lt 40 ]; do
    t=$(readlink "$f") || return 1
    case $t in
      /*) f=$t ;;
      *) f=${f%/*}/$t ;;
    esac
    n=$((n + 1))
  done
  d=$(cd -P "${f%/*}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "${f##*/}"
}

NN=0
NODE_SEEN=""
add_node() {
  local c=$1 r v
  [ -f "$c" ] && [ -x "$c" ] || return 0
  case $c in */shims/*) return 0 ;; esac
  [ "$c" = "${HOME:-}/.volta/bin/node" ] && return 0
  [ -n "${VOLTA_HOME:-}" ] && [ "$c" = "$VOLTA_HOME/bin/node" ] && return 0
  r=$(resolve_path "$c") || return 0
  case $r in */shims/*) return 0 ;; esac
  [ "${r##*/}" = node ] || return 0
  case "$NL$NODE_SEEN$NL" in *"$NL$r$NL"*) return 0 ;; esac
  NODE_SEEN=$NODE_SEEN$NL$r
  v=$(env -i "$r" --version 2>/dev/null < /dev/null | head -n 1)
  [[ $v =~ ^v?[0-9]+(\.[0-9]+)*$ ]] || v=""
  NODE_P[$NN]=$r
  NODE_V[$NN]=$v
  NN=$((NN + 1))
}

collect_node() {
  local d c H=${HOME:-} oldifs=$IFS
  set -f
  IFS=:
  for d in $USER_PATH:${CA_AUDIT_NODE_DIRS:-}; do
    case $d in /*) add_node "$d/node" ;; esac
  done
  IFS=$oldifs
  set +f
  if [ -n "$H" ]; then
    for c in "${NVM_DIR:-$H/.nvm}"/versions/node/*/bin/node "${NVM_DIR:-$H/.nvm}"/v*/bin/node \
      "${MISE_DATA_DIR:-$H/.local/share/mise}"/installs/node/*/bin/node \
      "${ASDF_DATA_DIR:-$H/.asdf}"/installs/nodejs/*/bin/node \
      "$H"/.fnm/node-versions/*/installation/bin/node \
      "$H"/.local/share/fnm/node-versions/*/installation/bin/node \
      "${FNM_DIR:-$H/.fnm}"/node-versions/*/installation/bin/node \
      "${VOLTA_HOME:-$H/.volta}"/tools/image/node/*/bin/node \
      "${NODENV_ROOT:-$H/.nodenv}"/versions/*/bin/node; do
      add_node "$c"
    done
  fi
  for c in "${N_PREFIX:-/usr/local}"/n/versions/node/*/bin/node \
    /opt/homebrew/Cellar/node*/*/bin/node /usr/local/Cellar/node*/*/bin/node; do
    add_node "$c"
  done
}

NA=0
collect_apps() {
  local rest d app fw v name
  if [ -n "${CA_AUDIT_APP_DIRS:-}" ]; then rest=$CA_AUDIT_APP_DIRS; else rest=/Applications:${HOME:-/nonexistent}/Applications; fi
  while [ -n "$rest" ]; do
    d=${rest%%:*}
    case $rest in
      *:*) rest=${rest#*:} ;;
      *) rest="" ;;
    esac
    [ -d "$d" ] || continue
    for app in "$d"/*.app; do
      fw="$app/Contents/Frameworks/Electron Framework.framework"
      [ -d "$fw" ] || continue
      v=$(plutil -extract CFBundleVersion raw -o - "$fw/Resources/Info.plist" 2> /dev/null)
      [[ $v =~ ^[0-9]+(\.[0-9]+)*$ ]] || v=""
      name=${app##*/}
      APP_N[$NA]=${name%.app}
      APP_V[$NA]=$v
      NA=$((NA + 1))
    done
  done
}

machine_section() {
  local f=$1 i
  if [ -z "$MAC_V" ]; then
    emit "UNCONFIRMED macOS: the version could not be read — run: sw_vers -productVersion"
  else
    check_version "$f" macos macOS macOS "$MAC_V"
  fi
  i=0
  while [ "$i" -lt "$NN" ]; do
    if [ -z "${NODE_V[$i]}" ]; then
      emit "UNCONFIRMED $(clean "${NODE_P[$i]}"): the Node version could not be read — run: ${NODE_P[$i]} --version"
    else
      check_version "$f" node "${NODE_P[$i]}" Node "${NODE_V[$i]}"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$NA" ]; do
    if [ -z "${APP_V[$i]}" ]; then
      if [ "$(meta_get_comp "$f" electron)" -gt 0 ]; then
        emit "UNCONFIRMED $(clean "${APP_N[$i]}"): the bundled Electron version could not be read — open the app's Electron Framework.framework/Resources/Info.plist and read CFBundleVersion"
      fi
    else
      check_version "$f" electron "${APP_N[$i]}" Electron "${APP_V[$i]}"
    fi
    i=$((i + 1))
  done
}

meta_get_comp() { CA_DATAFILE=$1 CA_WHAT=ncomp CA_COMP=$2 awk "$AWK_LIB"'BEGIN { load(ENVIRON["CA_DATAFILE"]); print NFIX[ENVIRON["CA_COMP"]] + 0 }'; }

PEM_MARK='-----BEGIN CERTIFICATE-----'

pem_stream() {
  {
    find -H "$ABS" -name .git -prune -o -type f -exec sh -c 'grep -l -F -e "$0" "$@" || [ $? -eq 1 ]' "$PEM_MARK" {} + 2> /dev/null
    printf '@rc %s\n' "$?"
  } | CA_ROOT=$ABS awk "$AWK_PEM_EXTRACT"
}

dockerfile_stream() {
  CA_DATAFILE=$1 CA_ROOT=$ABS find -H "$ABS" \( -name .git -o -name node_modules \) -prune -o -type f \
    \( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name '*.dockerfile' -o -name Containerfile -o -name 'Containerfile.*' \) \
    -exec awk "$AWK_LIB$AWK_DOCKER" {} + 2> /dev/null
  printf '@rc %s\n' "$?"
}

repo_section() {
  local f=$1 dout drc nseen n
  if [ "$(meta_get "$f" npkg)" -gt 0 ]; then
    dout=$(dockerfile_stream "$f")
    drc=${dout##*@rc }
    dout=$(printf '%s' "${dout%@rc *}" | awk "$AWK_SORT")
    nseen=$(printf '%s\n' "$dout" | awk '$0 == "@seen" { n++ } END { print n + 0 }')
    dout=$(printf '%s\n' "$dout" | awk '$0 != "@seen"')
    if [ "$drc" != 0 ]; then
      emit "UNCONFIRMED container build files: the search for Dockerfiles and Containerfiles did not complete (an unreadable directory or a tool failure), so some may have been missed — re-run as a user who can read the whole directory"
    fi
    if [ "$nseen" -gt 0 ]; then
      emit_lines "$dout"
    elif [ "$drc" = 0 ]; then
      emit "CLEAR container build files: none found"
    fi
  fi
  if [ "$(meta_get "$f" ncert)" -gt 0 ]; then
    if [ "$PEM_RC" != 0 ]; then
      emit "UNCONFIRMED certificate bundles: the search for PEM files did not complete (an unreadable directory or a tool failure), so a bundle holding a listed certificate may have been missed — re-run as a user who can read the whole directory"
    fi
    if [ "$HAVE_OPENSSL" = 1 ]; then
      emit_lines "$(printf '%s\n' "$HASHES" | CA_DATAFILE=$f CA_SCAN_RC=$PEM_RC awk "$AWK_LIB$AWK_PEM_MATCH")"
    elif [ -n "$NOSSL_FILES" ]; then
      n=$(printf '%s\n' "$NOSSL_FILES" | awk 'END { print NR }')
      emit "UNCONFIRMED certificate bundles: openssl was not found, so $n PEM file(s) could not be fingerprinted — confirm each with: openssl x509 -noout -fingerprint -sha256 -in <file> and compare it with the cert lines in the data file"
    elif [ "$PEM_RC" = 0 ]; then
      emit "CLEAR certificate bundles: no PEM files found"
    fi
  fi
}

mode=${1:-}
case $mode in
  machine) [ $# -eq 1 ] || usage ;;
  repo) [ $# -eq 2 ] || usage ;;
  *) usage ;;
esac

SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=$(cd "$(dirname "$SELF")" && pwd)
DATA_DIR=${CA_AUDIT_DATA_DIR:-$SCRIPT_DIR/../data}

DATAFILES=("$DATA_DIR"/*.tsv)
[ -f "${DATAFILES[0]}" ] || fail "no data files in $DATA_DIR"
for f in "${DATAFILES[@]}"; do
  [[ $(meta_get "$f" asof) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "$f has no as-of date in YYYY-MM-DD form"
  [ -n "$(meta_get "$f" event)" ] || fail "$f has no event line"
done

if [ "$mode" = machine ]; then
  [ "$(uname -s)" = Darwin ] || fail "machine mode runs on macOS only"
  if [ -n "${CA_AUDIT_MACOS_VERSION:-}" ]; then MAC_V=$CA_AUDIT_MACOS_VERSION; else MAC_V=$(sw_vers -productVersion 2> /dev/null); fi
  collect_node
  collect_apps
  printf 'CA distrust audit (read-only): machine\n'
else
  [ -d "$2" ] || fail "no such directory: $2"
  ABS=$(abspath "$2")
  HAVE_OPENSSL=0
  command -v openssl > /dev/null 2>&1 && HAVE_OPENSSL=1
  HASHES=""
  NOSSL_FILES=""
  PEM_OUT=$(pem_stream)
  PEM_RC=${PEM_OUT##*@rc }
  PEM_OUT=${PEM_OUT%@rc *}
  if [ "$HAVE_OPENSSL" = 1 ]; then
    HASHES=$(printf '%s' "$PEM_OUT" | while IFS=$TAB read -r rel b64; do
      [ -n "$rel" ] || continue
      h=$(printf '%s\n' "$b64" | openssl base64 -d -A 2> /dev/null | openssl dgst -sha256 2> /dev/null)
      printf '%s\t%s\n' "$rel" "${h##* }"
    done)
  else
    NOSSL_FILES=$(printf '%s' "$PEM_OUT" | cut -f1 | uniq)
  fi
  printf 'CA distrust audit (read-only): repo %s\n' "$(clean "$ABS")"
fi

for f in "${DATAFILES[@]}"; do
  printf 'Checked against: %s — fixed-version list as of %s (%s)\n' \
    "$(clean "$(meta_get "$f" event)")" "$(meta_get "$f" asof)" "$(clean "$(meta_get "$f" source)")"
  if [ "$mode" = machine ]; then machine_section "$f"; else repo_section "$f"; fi
done

if [ "$mode" = machine ]; then
  printf 'Not checked: %s\n' "$NOT_CHECKED_MACHINE"
else
  KS=$(find -H "$ABS" -name .git -prune -o -type f \( -name '*.jks' -o -name '*.p12' -o -name '*.pfx' -o -name '*.der' -o -name '*.p7b' -o -name cacerts \) -print 2> /dev/null | awk 'END { print NR }')
  printf 'Not checked: %s; binary keystores (%s found: .jks .p12 .pfx .der .p7b cacerts); %s\n' \
    "$NOT_CHECKED_REPO_HEAD" "$KS" "$NOT_CHECKED_REPO_TAIL"
fi

if [ "$REPORT_FLAG" = 1 ]; then
  echo "Verdict: FLAGGED"
elif [ "$REPORT_UNC" = 1 ]; then
  echo "Verdict: UNCONFIRMED"
else
  echo "Verdict: CLEAR"
fi
exit 0
