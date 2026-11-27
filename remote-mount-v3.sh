#!/usr/bin/env bash
# 远程存储挂载助手 v3：通过 rclone + systemd 挂载 FTP / FTPS / SFTP
set -euo pipefail
if [[ $(uname -s) != Linux ]]; then echo '仅支持 Linux。'; exit 1; fi
if [[ $EUID != 0 ]]; then echo '请用 root 运行，例如：sudo bash remote-mount-v3.sh'; exit 1; fi
if ! (: </dev/tty) 2>/dev/null; then echo '需要在交互式终端中运行（找不到 /dev/tty）。'; exit 1; fi
if ! command -v python3 >/dev/null; then
  echo '需要安装 Python 3。'
  answer=''
  # 从 /dev/tty 读取：通过 curl | bash 运行时 stdin 是脚本本身
  read -r -p '现在从系统软件源安装？[y/N] ' answer </dev/tty || true
  [[ $answer == [yY] ]] || exit 1
  if command -v apt-get >/dev/null; then apt-get update && apt-get install -y python3
  elif command -v dnf >/dev/null; then dnf install -y python3
  else echo '请先手动安装 python3。'; exit 1; fi
fi
exec python3 - <<'PY'
import os, sys, re, io, json, pwd, shutil, getpass, pathlib, tempfile, fcntl, configparser
import subprocess as sp

if sys.version_info < (3, 7): sys.exit('需要 Python 3.7 或更高版本。')
sys.stdin = open('/dev/tty')
os.umask(0o077)

BASE = pathlib.Path('/etc/remote-mount-helper')
UNIT_DIR = pathlib.Path('/etc/systemd/system')
CACHE_BASE = pathlib.Path('/var/cache/remote-mount-helper')
CLEANUP = BASE / 'stale-cleanup.sh'
MIN_RCLONE = (1, 60)
SUFFIXES = ['.conf', '.json', '.known_hosts', '.key']
BAD_PATH = re.compile(r'[\s%$\\"\'`]')
SIZE_RE = re.compile(r'(\d+)([MG])')
# 不允许挂载到这些目录或其子目录（/tmp 等会被 systemd-tmpfiles 清理，可能误删远程文件）
FORBIDDEN = ['/proc', '/sys', '/dev', '/run', '/boot', '/etc', '/usr', '/bin', '/sbin',
             '/lib', '/lib32', '/lib64', '/libx32', '/var/lib', '/var/cache', '/var/log',
             '/tmp', '/var/tmp']

BASE.mkdir(mode=0o700, exist_ok=True); os.chmod(BASE, 0o700)
lock = open(BASE / 'lock', 'w')
try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit('已有另一个脚本正在运行。')

# ---------- 通用工具 ----------
def ask(s, default=''):
    v = input(s + (f' [{default}]' if default else '') + '：').strip()
    return v or default
def yes(s): return ask(s + '（y 确认，回车取消）').lower() == 'y'
def run(args, check=True, **kw): return sp.run(args, check=check, **kw)
def out(args): return sp.check_output(args, text=True, stderr=sp.DEVNULL).strip()
def quiet(args): return run(args, check=False, stdout=sp.DEVNULL, stderr=sp.DEVNULL).returncode == 0
def rm(p):
    try: os.unlink(p)
    except FileNotFoundError: pass
def atomic(p, data, mode=0o600):
    p = pathlib.Path(p)
    fd, tmp = tempfile.mkstemp(dir=p.parent, prefix='.tmp-')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, p)
        dfd = os.open(p.parent, os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        rm(tmp)
def sq(s):
    # systemd 参数语法：转义说明符、环境变量展开和引号
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'
def unit(n): return 'remote-mount-' + n + '.service'
def fusermount(): return shutil.which('fusermount3') or shutil.which('fusermount')
def size_bytes(s):
    m = SIZE_RE.fullmatch(s); return int(m[1]) * (1024 ** 3 if m[2] == 'G' else 1024 ** 2)
def gb(b): return f'{b / 1024 ** 3:.1f} GB'
def has_files(d):
    d = pathlib.Path(d)
    try: return d.is_dir() and any(p.is_file() for p in d.rglob('*'))
    except OSError: return True   # 读不了就当作有数据，宁可保留

# ---------- 挂载状态 ----------
def mounts():
    """挂载点 → 文件系统类型；同一路径叠加多次挂载时，保留最上层那个。"""
    res = {}
    with open('/proc/self/mountinfo') as f:
        for line in f:
            pre, _, post = line.partition(' - ')
            mp = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), pre.split()[4])
            res[mp] = post.split()[0]
    return res
def fstype(p): return mounts().get(str(p))
def mounted(p): return fstype(p) is not None
def active(u): return quiet(['systemctl', 'is-active', '--quiet', u])
def usable(p):
    # 只检查本地目录能否响应（可能命中目录缓存），不代表远程当前可连接
    pr = sp.Popen(['ls', '-A', '--', str(p)], stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    try: return pr.wait(timeout=20) == 0
    except sp.TimeoutExpired:
        pr.kill()
        try: pr.wait(timeout=5)
        except sp.TimeoutExpired: pass   # 卡在内核里的进程杀不掉，不再等它
        return False
def users_of(p):
    # 只读 /proc 里的符号链接，不访问挂载本身，挂载卡死时也不会阻塞。
    # 注意：容器等其他挂载命名空间里的进程可能查不到，最终以普通卸载是否成功为准。
    p = str(p); found = {}
    for d in pathlib.Path('/proc').iterdir():
        if not d.name.isdigit() or int(d.name) == os.getpid(): continue
        links = [d / 'cwd']
        try: links += list((d / 'fd').iterdir())
        except OSError: pass
        for l in links:
            try: t = os.readlink(l)
            except OSError: continue
            if t == p or t.startswith(p + '/'):
                try: comm = (d / 'comm').read_text().strip()
                except OSError: comm = '?'
                found[int(d.name)] = comm; break
    return found
def show_users(busy):
    print('以下进程正在使用该目录：')
    for pid, c in busy.items(): print(f'  PID {pid}  {c}')
def set_immutable(p, on):
    return bool(shutil.which('chattr')) and quiet(['chattr', '+i' if on else '-i', str(p)])
def lazy_unmount(p):
    """只用于“强制修复”和回滚刚创建的挂载。调用前必须确认是 rclone 挂载。"""
    f = fusermount()
    if f: quiet([f, '-uz', str(p)])
    if mounted(p): quiet(['umount', '-l', str(p)])
    return not mounted(p)
def write_cleanup_helper():
    # ExecStopPost 在 rclone 退出（含崩溃）后调用：只在最上层挂载是 fuse.rclone 时清理，
    # 此时 rclone 已不在，这个挂载必然已失效，清理是安全的。
    atomic(CLEANUP, '\n'.join([
        '#!/bin/sh',
        '# 由 remote-mount 服务的 ExecStopPost 调用，只清理 rclone 退出后残留的失效挂载',
        'm="$1"',
        '[ -n "$m" ] || exit 0',
        'awk -v m="$m" \'$5==m { f=0; split($0,a," - "); split(a[2],b," "); if (b[1]=="fuse.rclone") f=1 } '
        'END { exit !f }\' /proc/self/mountinfo || exit 0',
        f'exec {fusermount()} -uz "$m"', '']), 0o700)

# ---------- 依赖与 rclone ----------
def rclone_version():
    try: m = re.search(r'v(\d+)\.(\d+)', out(['rclone', 'version']))
    except (OSError, sp.CalledProcessError): return None
    return (int(m[1]), int(m[2])) if m else None
def mount_supports(flag):
    try: return flag in out(['rclone', 'mount', '--help'])
    except (OSError, sp.CalledProcessError): return False
def deps(need_ssh):
    if not pathlib.Path('/run/systemd/system').exists():
        raise ValueError('需要使用 systemd 的 Linux 主机；不支持 OpenWrt 或普通容器。')
    def missing():
        tools = ['rclone', 'umount', 'awk'] + (['ssh-keyscan', 'ssh-keygen'] if need_ssh else [])
        m = [x for x in tools if not shutil.which(x)]
        if not fusermount(): m.append('FUSE（fusermount3）')
        return m
    if missing():
        print('缺少依赖：' + '、'.join(missing()))
        if not yes('从系统软件源安装？'): raise ValueError('已取消。')
        pk = ['rclone', 'fuse3', 'util-linux', 'e2fsprogs']
        if shutil.which('apt-get'):
            run(['apt-get', 'update']); run(['apt-get', 'install', '-y'] + pk + (['openssh-client'] if need_ssh else []))
        elif shutil.which('dnf'):
            if run(['dnf', 'install', '-y'] + pk + (['openssh-clients'] if need_ssh else []), check=False).returncode:
                raise ValueError('安装失败。RHEL / Rocky / Alma 需先启用 EPEL（dnf install epel-release），'
                                 '或从 https://rclone.org/downloads/ 安装 rclone。')
        else: raise ValueError('暂只支持 apt-get / dnf 自动安装，请手动安装上述依赖。')
        if missing(): raise ValueError('仍缺少依赖：' + '、'.join(missing()))
    v = rclone_version()
    if not v or v < MIN_RCLONE:
        cur = f'v{v[0]}.{v[1]}' if v else '未知'
        raise ValueError(f'rclone 版本过旧（当前 {cur}，需要 ≥ v{MIN_RCLONE[0]}.{MIN_RCLONE[1]}）。'
                         '旧版本可能不认识“显式 FTPS”等选项，并悄悄改用明文连接。\n'
                         '系统软件源里的版本经常偏旧，请从 https://rclone.org/downloads/ 安装官方版本后重试。')
    if not pathlib.Path('/dev/fuse').exists(): run(['modprobe', 'fuse'], check=False)
    if not pathlib.Path('/dev/fuse').exists(): raise ValueError('没有 /dev/fuse，请让主机管理员启用 FUSE。')
def obscure(pw):
    o = sp.run(['rclone', 'obscure', '-'], input=pw + '\n', text=True, stdout=sp.PIPE, check=True).stdout.strip()
    back = sp.run(['rclone', 'reveal', o], text=True, stdout=sp.PIPE, check=True).stdout.rstrip('\n')
    if not o or back != pw: raise ValueError('rclone 处理密码失败（可能是密码首尾含空格），请换一个密码或升级 rclone。')
    return o
def password(label='登录密码'):
    a = getpass.getpass(label + '（输入不显示）：'); b = getpass.getpass('再次输入：')
    if a != b: raise ValueError('两次密码不同。')
    if not a: raise ValueError('密码不能为空。')
    return obscure(a)
def test_remote(conf, remote):
    print('测试远程连接，最长约 60 秒……')
    try:
        run(['rclone', 'lsf', remote, '--config', str(conf), '--max-depth', '1', '--contimeout', '10s',
             '--timeout', '20s', '--retries', '1', '--low-level-retries', '1'],
            stdout=sp.DEVNULL, stderr=sp.PIPE, text=True, timeout=60)
    except sp.TimeoutExpired:
        raise ValueError('连接超时。FTP 常见原因是被动模式数据端口没放行；可以开启“旧服务器兼容”，或联系服务商。')
    except sp.CalledProcessError as e:
        tail = '\n'.join((e.stderr or '').strip().splitlines()[-3:])
        raise ValueError('连接测试失败：\n' + tail + '\n请检查协议、账号密码、远程路径和证书设置。')

# ---------- FTPS 自签名证书 ----------
def trust_store():
    deb = pathlib.Path('/usr/local/share/ca-certificates')
    rhel = pathlib.Path('/etc/pki/ca-trust/source/anchors')
    if deb.is_dir() and shutil.which('update-ca-certificates'): return deb, ['update-ca-certificates']
    if rhel.is_dir() and shutil.which('update-ca-trust'): return rhel, ['update-ca-trust', 'extract']
    return None
def refresh_trust():
    ts = trust_store()
    return bool(ts) and quiet(ts[1])
def import_cert(n, host, port, implicit):
    """获取服务器证书，核对指纹后加入系统信任列表（rclone 在 Linux 上使用系统证书库）。"""
    if not shutil.which('openssl'): raise ValueError('需要 openssl 命令来获取证书，请先安装 openssl。')
    ts = trust_store()
    if not ts: raise ValueError('没找到系统证书库（update-ca-certificates / update-ca-trust）。')
    target = f'[{host}]:{port}' if ':' in host else f'{host}:{port}'
    args = ['openssl', 's_client', '-connect', target, '-showcerts']
    if not re.fullmatch(r'[\d.]+', host) and ':' not in host: args += ['-servername', host]
    if not implicit: args += ['-starttls', 'ftp']
    try: r = run(args, check=False, input='', stdout=sp.PIPE, stderr=sp.DEVNULL, text=True, timeout=20)
    except sp.TimeoutExpired: raise ValueError('获取证书超时。')
    m = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', r.stdout, re.S)
    if not m: raise ValueError('没能从服务器获取证书，请检查协议（显式/隐式）和端口。')
    pem = m.group(0) + '\n'
    tmp = BASE / (n + '.crt.tmp')
    try:
        atomic(tmp, pem, 0o644)
        print(out(['openssl', 'x509', '-in', str(tmp), '-noout', '-subject', '-issuer', '-enddate',
                   '-fingerprint', '-sha256']))
        san = run(['openssl', 'x509', '-in', str(tmp), '-noout', '-ext', 'subjectAltName'],
                  check=False, stdout=sp.PIPE, stderr=sp.DEVNULL, text=True).stdout.strip()
        print(san or '（证书里没有 subjectAltName：现在的验证会忽略 CN，很可能仍然验证失败）')
        print(f'请与服务商提供的 SHA256 指纹核对。证书里的域名/IP 必须包含你填写的主机 {host}，否则验证仍会失败。')
        if not yes('确认这个证书属于目标服务器，并加入本机信任列表？'): raise ValueError('未信任该证书，已取消。')
        dest = ts[0] / f'remote-mount-{n}.crt'
        atomic(dest, pem, 0o644)
    finally: rm(tmp)
    if not refresh_trust():
        rm(dest); refresh_trust()
        raise ValueError('更新系统证书库失败。')
    print('已加入信任列表：' + str(dest) + '（本机其他程序也会信任这个证书）')
    return dest

# ---------- 配置记录 ----------
def metas():
    res = {}
    for p in sorted(BASE.glob('*.json')):
        try: res[p.stem] = json.loads(p.read_text())
        except (OSError, ValueError): print('无法读取配置：' + p.name)
    return res
def orphans():
    stems = {p.name[:-len(s)] for s in ['.conf', '.known_hosts', '.key'] for p in BASE.glob('*' + s)}
    return sorted(s for s in stems if not (BASE / (s + '.json')).exists())
def select():
    ms = metas()
    if not ms: raise ValueError('还没有配置，请先新增。')
    names = list(ms)
    for i, n in enumerate(names, 1):
        print(f'{i}. {n} → {ms[n]["mount"]}（{"已挂载" if mounted(ms[n]["mount"]) else "未挂载"}）')
    s = ask('选择编号')
    if not s.isdigit() or not 1 <= int(s) <= len(names): raise ValueError('编号无效。')
    n = names[int(s) - 1]; return n, ms[n]
def check_mount(s):
    if not s.startswith('/') or BAD_PATH.search(s):
        raise ValueError('挂载路径必须是绝对路径，且不能包含空格或 % $ \\ " \' ` 等特殊字符。')
    p = pathlib.Path(s).resolve(); ps = str(p)
    if BAD_PATH.search(ps): raise ValueError(f'该路径解析符号链接后为 {ps}，包含特殊字符，不支持。')
    if len(p.parts) < 3: raise ValueError('请至少用两级目录（例如 /mnt/myftp），不要直接挂到 /、/mnt、/data 这类一级目录。')
    for f in FORBIDDEN:
        if ps == f or ps.startswith(f + '/'): raise ValueError(f'不允许挂载到系统目录 {f} 下。')
    for name, m in metas().items():
        o = m['mount']
        if ps == o or ps.startswith(o + '/') or o.startswith(ps + '/'):
            raise ValueError(f'该路径与已有连接 {name}（{o}）重叠。')
    if mounted(p): raise ValueError('该目录上已有挂载。')
    if p.exists() and (not p.is_dir() or any(p.iterdir())): raise ValueError('目录已存在且不是空目录，拒绝覆盖。')
    return p

# ---------- 新增 ----------
def create():
    n = ask('连接名称（字母开头，只用小写字母、数字、短横线，例如 myftp）')
    if not re.fullmatch('[a-z][a-z0-9-]{0,30}', n): raise ValueError('名称不符合要求。')
    unitp = UNIT_DIR / unit(n)
    if any((BASE / (n + s)).exists() for s in SUFFIXES) or unitp.exists():
        raise ValueError('该名称已被使用（配置或同名 systemd 服务已存在），请换一个名称或先删除旧配置。')
    print('1. FTP（明文）  2. 显式 FTPS（推荐）  3. 隐式 FTPS  4. SFTP（SSH）')
    kind = ask('选择协议', '2')
    if kind not in ['1', '2', '3', '4']: raise ValueError('协议选项无效。')
    if kind == '1' and not yes('明文 FTP 会明文传输账号、密码和数据，在公网上可能被窃听。确认继续？'):
        raise ValueError('已取消。')
    deps(kind == '4')
    host = ask('主机 IP 或域名（不要加协议、路径或端口）')
    if not host or host.startswith('-') or re.search(r'[\s/\[\]@?#]', host):
        raise ValueError('主机格式错误（IPv6 地址不要加方括号）。')
    port = ask('端口', '22' if kind == '4' else '990' if kind == '3' else '21')
    if not port.isdigit() or not 1 <= int(port) <= 65535: raise ValueError('端口必须是 1～65535。')
    user = ask('登录账号')
    if not user: raise ValueError('账号不能为空。')
    cfg = {'type': 'sftp' if kind == '4' else 'ftp', 'host': host, 'port': port, 'user': user}

    # 回滚需要的状态
    created, made_dirs = [], []
    unit_written = reloaded = started = protected = False
    mount = cache_dir = orig_mode = cert_path = None

    def rollback():
        failed = []
        def step(desc, fn):
            try:
                if fn() is False: failed.append(desc)
            except Exception as e: failed.append(f'{desc}（{e}）')
        if reloaded:
            step('停止并禁用服务', lambda: quiet(['systemctl', 'disable', '--now', unit(n)]))
        if mount is not None and fstype(mount) == 'fuse.rclone':
            step('卸载刚建立的挂载', lambda: lazy_unmount(mount))
        if unit_written:
            step('删除服务文件', lambda: rm(unitp))
        if reloaded:
            step('重新加载 systemd', lambda: quiet(['systemctl', 'daemon-reload']))
            quiet(['systemctl', 'reset-failed', unit(n)])
        if protected: step('取消目录的不可修改属性', lambda: set_immutable(mount, False))
        if orig_mode is not None: step('恢复目录原权限', lambda: os.chmod(mount, orig_mode))
        for d in made_dirs: step(f'删除目录 {d}', lambda d=d: d.rmdir())
        for f in created: step(f'删除文件 {f}', lambda f=f: rm(f))
        if cert_path: step('移除导入的证书', lambda: (rm(cert_path), refresh_trust())[1])
        if cache_dir: step('删除缓存目录', lambda: shutil.rmtree(cache_dir))
        left = [str(p) for p in created if p.exists()]
        if unit_written and unitp.exists(): left.append(str(unitp))
        if cert_path and cert_path.exists(): left.append(str(cert_path))
        if mount is not None and mounted(mount): left.append(f'{mount}（仍处于挂载状态）')
        if failed or left:
            print('回滚没有完全成功，请手动检查：')
            for x in failed: print('  失败：' + x)
            for x in left: print('  残留：' + x)
        else:
            print('已撤销本次新增的全部改动。')

    try:
        if kind == '4':
            auth = ask('认证方式：1 密码，2 私钥', '1')
            if auth == '2':
                src = pathlib.Path(ask('本机私钥文件绝对路径')).expanduser()
                if not src.is_absolute() or not src.is_file(): raise ValueError('私钥文件不存在。')
                keyp = BASE / (n + '.key')
                shutil.copyfile(src, keyp); created.append(keyp); os.chmod(keyp, 0o600)
                cfg['key_file'] = str(keyp)   # 复制一份，原文件移动或删除后不影响挂载
                pw = getpass.getpass('私钥口令（无则回车）：')
                if pw: cfg['key_file_pass'] = obscure(pw)
            elif auth == '1': cfg['pass'] = password()
            else: raise ValueError('认证选项无效。')
            print('正在获取服务器公钥，请与服务商提供的 SSH 指纹核对。')
            scan = run(['ssh-keyscan', '-T', '8', '-p', port, host], check=False,
                       stdout=sp.PIPE, stderr=sp.DEVNULL, text=True)
            if not scan.stdout.strip(): raise ValueError('无法获取 SSH 公钥，请检查地址和端口。')
            known = BASE / (n + '.known_hosts'); atomic(known, scan.stdout); created.append(known)
            run(['ssh-keygen', '-lf', str(known)])
            if not yes('确认指纹属于目标服务器？'): raise ValueError('未信任该服务器，已取消。')
            cfg['known_hosts_file'] = str(known)
        else:
            cfg['pass'] = password()
            cfg['tls'] = 'true' if kind == '3' else 'false'
            cfg['explicit_tls'] = 'true' if kind == '2' else 'false'
            if kind in ('2', '3'):
                print('证书验证：\n'
                      '  1. 使用系统信任的证书（默认，适合正规机构签发的证书）\n'
                      '  2. 服务器用的是自签名证书：获取证书、核对指纹后加入本机信任列表\n'
                      '  3. 跳过证书验证（不推荐：无法确认服务器身份，密码可能被中间人截获）')
                cv = ask('选择', '1')
                if cv == '2': cert_path = import_cert(n, host, port, kind == '3')
                elif cv == '3':
                    if not yes('跳过验证后，任何冒充服务器的人都可能拿到你的密码。确认跳过？'): raise ValueError('已取消。')
                    cfg['no_check_certificate'] = 'true'
                elif cv != '1': raise ValueError('证书选项无效。')
            print('并发连接数：默认不限制（推荐）。只有服务商限制了同时连接数（常见报错 421 Too many connections）时才需要设置。\n'
                  '设置后，同时打开的文件超过这个数时，新的读写会一直排队，严重时整个挂载会卡住。')
            c = ask('最大连接数（0 表示不限制）', '0')
            if not c.isdigit() or not 0 <= int(c) <= 64: raise ValueError('连接数需为 0～64。')
            if c != '0': cfg['concurrency'] = c
            if yes('开启旧服务器兼容（关闭 EPSV 和 MLSD）？一般不需要，连接测试失败时再试'):
                cfg['disable_epsv'] = 'true'; cfg['disable_mlsd'] = 'true'
        path = ask('远程目录（回车使用账号默认目录；例如 /backup）')

        mount = check_mount(ask('本地挂载目录（必须是空目录或不存在的目录）', '/mnt/' + n))
        if mount.exists():
            if not yes('该空目录已存在，权限会被改成 000 并加“不可修改”属性，继续？'): raise ValueError('已取消。')
            orig_mode = mount.stat().st_mode & 0o7777

        who = ask('允许哪个本地用户访问挂载内容？（回车表示仅 root）')
        access = []
        if who:
            try: acct = pwd.getpwnam(who)
            except KeyError: raise ValueError('本地用户不存在：' + who)
            # --default-permissions 让内核按 uid/umask 检查权限，否则 allow-other 会对所有用户开放
            access = ['--allow-other', '--default-permissions', '--uid', str(acct.pw_uid), '--gid', str(acct.pw_gid)]

        print('缓存模式：\n'
              '  1. 不落盘：只支持顺序读写，适合 cp / rsync 普通复制；随机写、原地修改、部分软件会报错\n'
              '  2. 写入缓存：写入先存本机磁盘再后台上传，兼容性好；需要本地空间，文件关闭后才开始上传')
        cm = ask('选择', '1')
        if cm == '1': cache_args = ['--vfs-cache-mode', 'off']
        elif cm == '2':
            CACHE_BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
            free = shutil.disk_usage(CACHE_BASE).free
            print(f'缓存目录 {CACHE_BASE} 所在磁盘当前剩余 {gb(free)}。\n'
                  '注意：下面的“清理目标”不是硬性上限。正在打开或还没上传完的文件不会被清理，\n'
                  '写入大文件或上传变慢时，缓存仍可能超过这个值，甚至占满磁盘。')
            size = ask('缓存清理目标（如 2G、500M）', '5G')
            if not SIZE_RE.fullmatch(size): raise ValueError('格式错误，例如 5G 或 500M。')
            if size_bytes(size) > free * 0.8 and not yes(f'清理目标超过剩余空间的 80%（剩余 {gb(free)}），磁盘很可能被占满。仍然继续？'):
                raise ValueError('已取消。')
            cd = CACHE_BASE / n
            if cd.exists(): raise ValueError(f'缓存目录 {cd} 已存在（可能有旧数据），请先检查并移走后重试。')
            cd.mkdir(mode=0o700); cache_dir = cd
            cache_args = ['--vfs-cache-mode', 'writes', '--cache-dir', str(cache_dir),
                          '--vfs-cache-max-size', size, '--vfs-cache-max-age', '24h']
            if mount_supports('--vfs-cache-min-free-space'):
                mf = ask('尽量保留的磁盘空闲空间（同样不是硬性保证）', '2G')
                if not SIZE_RE.fullmatch(mf): raise ValueError('格式错误，例如 2G 或 500M。')
                cache_args += ['--vfs-cache-min-free-space', mf]
            else:
                print('当前 rclone 不支持 --vfs-cache-min-free-space，未设置空闲空间目标。')
        else: raise ValueError('缓存选项无效。')
        boot = yes('是否开机自动挂载？')

        conf = BASE / (n + '.conf')
        parser = configparser.ConfigParser(interpolation=None); parser[n] = cfg
        buf = io.StringIO(); parser.write(buf); atomic(conf, buf.getvalue()); created.append(conf)
        remote = n + ':' + path
        test_remote(conf, remote)

        # 建目录：中间目录设为 755，方便授权用户进入
        q = mount; todo = []
        while not q.exists(): todo.append(q); q = q.parent
        for d in reversed(todo):
            d.mkdir(); os.chmod(d, 0o755); made_dirs.insert(0, d)
        os.chmod(mount, 0o000)
        protected = set_immutable(mount, True)

        write_cleanup_helper()
        mq = sq(str(mount))
        args = [shutil.which('rclone'), 'mount', remote, str(mount), '--config', str(conf),
                '--dir-cache-time', '30s', '--umask', '077', '--log-level', 'NOTICE'] + cache_args + access
        text = '\n'.join([
            '[Unit]', 'Description=Remote storage mount ' + n,
            'Wants=network-online.target', 'After=network-online.target', 'StartLimitIntervalSec=0', '',
            '[Service]', 'Type=notify',
            'ExecStart=' + ' '.join(map(sq, args)),
            f'ExecStop={fusermount()} -u {mq}',
            # rclone 退出（含崩溃）后才执行；只清理残留的 rclone 失效挂载，让自动重启能成功
            f'ExecStopPost=-/bin/sh {sq(str(CLEANUP))} {mq}',
            'Restart=on-failure', 'RestartSec=15', 'TimeoutStartSec=90',
            'TimeoutStopSec=' + ('300' if cache_dir else '30'), '',
            '[Install]', 'WantedBy=multi-user.target', ''])
        unit_written = True
        atomic(unitp, text, 0o644)
        meta = BASE / (n + '.json')
        atomic(meta, json.dumps({
            'mount': str(mount), 'remote': remote, 'made_dir': mount in made_dirs,
            'orig_mode': orig_mode, 'cache_dir': str(cache_dir) if cache_dir else None,
            'protected': protected, 'ca_cert': str(cert_path) if cert_path else None},
            ensure_ascii=False))
        created.append(meta)
        run(['systemctl', 'daemon-reload']); reloaded = True
        if boot: run(['systemctl', 'enable', unit(n)])
        started = True
        run(['systemctl', 'start', unit(n)], check=False)
        # Type=notify：服务进入 active 就表示 rclone 已完成挂载
        if not (active(unit(n)) and fstype(mount) == 'fuse.rclone'):
            run(['journalctl', '-u', unit(n), '-n', '20', '--no-pager'], check=False)
            raise ValueError('挂载未成功（上面是日志）。')
    except BaseException as e:
        if started and cache_dir and has_files(cache_dir):
            print('新增过程出错：' + (str(e) or type(e).__name__))
            print(f'写入缓存 {cache_dir} 里已经有文件，可能还没上传。为避免丢数据，本次的配置、服务和缓存都已保留，'
                  f'连接 {n} 会出现在菜单里。\n处理办法：用 3 重启挂载让它继续上传；确认数据不需要后，再用 7 删除。')
            if isinstance(e, (KeyboardInterrupt, EOFError)): raise
            return
        rollback(); raise

    print(f'\n挂载成功：{mount}')
    if not usable(mount):
        print('警告：挂载已建立，但列目录 20 秒内没有响应（远程目录很大或网络慢时可能这样）。稍后可用菜单 2 检查。')
    print('- 访问权限：' + (f'root 和用户 {who}' if who else '仅 root'))
    print('- 未挂载时该目录' + ('已设为不可写（chattr +i），root 也写不进去' if protected else
          '没能加不可修改属性（缺少 chattr 或文件系统不支持），root 仍可能误写本地磁盘，复制前请先用 mountpoint -q 检查'))
    if cache_dir:
        print('- 写入缓存模式：文件关闭后在后台上传；没上传完的文件留在缓存里，下次启动时继续上传')
    print(f'- 其他服务（如备份）依赖这个挂载时，在它的 unit 里加：\n    Requires={unit(n)}\n    After={unit(n)}')
    print('- Docker 容器要用这个目录，需在挂载完成后再启动容器（或使用 rshared 挂载传播）')
    print('- 配置里的密码只是混淆不是加密，安全性依赖 /etc/remote-mount-helper 只有 root 可读')

# ---------- 菜单操作 ----------
def release(u, mount, disable=False):
    """普通卸载并停止服务。目录被占用或卸载失败时只报告，不强制，返回 False。"""
    t = fstype(mount)
    if t and t != 'fuse.rclone':
        print(f'{mount} 上现在是 {t} 类型的挂载，不是本助手的 rclone 挂载，不处理。')
        return False
    if t:
        busy = users_of(mount)
        if busy:
            show_users(busy)
            print('请先结束这些进程后重试。如果确认挂载已失效，可用菜单 8 强制修复。')
            return False
        r = run([fusermount(), '-u', mount], check=False, stdout=sp.DEVNULL, stderr=sp.PIPE, text=True)
        if r.returncode:
            print('普通卸载失败：' + r.stderr.strip())
            print('目录可能仍在被使用（例如容器里的进程）。如果确认挂载已失效，可用菜单 8 强制修复。')
            return False
    # 卸载后 rclone 会自行退出；这里再停止服务，同时取消可能已排队的自动重启
    run(['systemctl', 'disable', '--now', u] if disable else ['systemctl', 'stop', u], check=False)
    return True
def start(u, mount):
    run(['systemctl', 'start', u], check=False)
    if active(u) and fstype(mount) == 'fuse.rclone':
        print('已挂载。'); return True
    print('挂载未成功，请用菜单 5 查看日志。'); return False
def status(n, m):
    u, mount = unit(n), m['mount']
    run(['systemctl', 'status', u, '--no-pager', '-l'], check=False)
    t = fstype(mount)
    print('挂载：' + (f'存在（{t}）' if t else '不存在'))
    if t:
        print('本地目录响应：' + ('正常（可能来自目录缓存，不代表远程当前可连接）' if usable(mount)
                                else '无响应。挂载可能已失效，可用菜单 8 强制修复'))
    if m.get('cache_dir') and pathlib.Path(m['cache_dir']).exists():
        run(['du', '-sh', m['cache_dir']], check=False)
    if yes('现在做一次远程连接测试？'):
        try: test_remote(BASE / (n + '.conf'), m.get('remote') or n + ':'); print('远程连接：正常')
        except ValueError as e: print('远程连接：' + str(e))
def force_repair(n, m):
    u, mount = unit(n), m['mount']
    t = fstype(mount)
    if t and t != 'fuse.rclone':
        raise ValueError(f'{mount} 上的挂载类型是 {t}，不是 rclone 挂载，拒绝处理。')
    if t:
        busy = users_of(mount)
        if busy: show_users(busy)
        if not yes('强制修复会立即断开这个挂载，正在使用它的程序会读写失败；'
                   '写入缓存里没上传的文件会保留，下次启动继续上传。确认？'): return
        run(['systemctl', 'stop', u], check=False)
        if fstype(mount) == 'fuse.rclone': lazy_unmount(mount)
        if mounted(mount): raise ValueError(f'仍无法卸载 {mount}，请检查 journalctl 和占用进程。')
        print('已断开挂载。')
    else:
        print('该目录当前没有挂载。')
        run(['systemctl', 'stop', u], check=False)
    if yes('现在重新启动挂载？'): start(u, mount)
def change_secret(n, m):
    conf = BASE / (n + '.conf')
    p = configparser.ConfigParser(interpolation=None); p.read(conf)
    if n not in p: raise ValueError('配置文件缺失或损坏。')
    sec = p[n]
    if sec.get('key_file'):
        pw = getpass.getpass('新的私钥口令（无口令则回车）：')
        if pw: sec['key_file_pass'] = obscure(pw)
        else: sec.pop('key_file_pass', None)
    else: sec['pass'] = password('新的登录密码')
    buf = io.StringIO(); p.write(buf)
    tmp = BASE / (n + '.conf.new')
    try:
        atomic(tmp, buf.getvalue())
        test_remote(tmp, m.get('remote') or n + ':')
        os.replace(tmp, conf)
    finally: rm(tmp)
    print('已保存新密码。')
    if active(unit(n)) and yes('需要重启挂载才能使用新密码，现在重启？'):
        if release(unit(n), m['mount']): start(unit(n), m['mount'])
        else: print('没有重启，新密码会在下次重启挂载后生效。')
def delete(n, m):
    u, mount = unit(n), m['mount']
    if not yes(f'删除连接 {n}：停止挂载、取消开机挂载，并删除保存的账号、密钥、缓存和服务文件。'
               '不会删除远程文件。确认？'): return
    cache = m.get('cache_dir')
    if cache and has_files(cache) and not yes(f'写入缓存 {cache} 里还有文件，可能没上传完，删除后会丢失。仍然删除？'):
        return
    if not release(u, mount, disable=True):
        print('没有删除任何配置。'); return
    rm(UNIT_DIR / u)
    run(['systemctl', 'daemon-reload']); quiet(['systemctl', 'reset-failed', u])
    if cache: shutil.rmtree(cache, ignore_errors=True)
    if m.get('ca_cert'):
        rm(m['ca_cert'])
        if not refresh_trust(): print('提示：更新系统证书库失败，请手动执行 update-ca-certificates 或 update-ca-trust。')
    mp = pathlib.Path(mount)
    if not mounted(mp):
        set_immutable(mp, False)
        try:
            if mp.is_dir() and not any(mp.iterdir()):
                if m.get('made_dir'): mp.rmdir(); print('已删除本地空目录 ' + mount)
                elif m.get('orig_mode') is not None: os.chmod(mp, m['orig_mode'])
                else: print(f'本地目录 {mount} 已保留（权限仍为 000，可自行调整或删除）。')
        except OSError as e: print('本地目录处理失败：' + str(e))
    for s in SUFFIXES: rm(BASE / (n + s))
    print('已删除连接配置。')
def clean_orphans():
    os_ = orphans()
    if not os_: return
    print('发现以前未完成的残留配置（可能含密码）：' + '、'.join(os_))
    if not yes('删除这些残留？'): return
    for n in os_:
        if (UNIT_DIR / unit(n)).exists():
            quiet(['systemctl', 'disable', '--now', unit(n)])
            rm(UNIT_DIR / unit(n))
        for s in SUFFIXES: rm(BASE / (n + s))
    run(['systemctl', 'daemon-reload'], check=False)
    print('已清理。')

print('远程存储挂载助手 v3｜FTP / FTPS / SFTP\n不会删除远程文件。')
try: clean_orphans()
except (OSError, sp.SubprocessError) as e: print('清理残留失败：' + str(e))
except (KeyboardInterrupt, EOFError): print('\n已退出。'); sys.exit(0)
while True:
    print('\n1 新增并挂载\n2 状态（可做远程连接测试）\n3 重启挂载\n4 卸载并取消开机挂载（保留配置）'
          '\n5 查看日志\n6 修改登录密码 / 私钥口令\n7 删除连接配置\n8 强制修复失效挂载\n0 退出')
    try:
        action = ask('选择', '0')
        if action == '0': break
        if action == '1': create(); continue
        if action not in ['2', '3', '4', '5', '6', '7', '8']: continue
        n, m = select(); u, mount = unit(n), m['mount']
        if action == '2': status(n, m)
        elif action == '3':
            if release(u, mount): start(u, mount)
            if not quiet(['systemctl', 'is-enabled', '--quiet', u]) and yes('启用开机自动挂载？'):
                run(['systemctl', 'enable', u])
        elif action == '4':
            if release(u, mount, disable=True): print('已卸载，开机自动挂载已关闭。')
        elif action == '5': run(['journalctl', '-u', u, '-n', '60', '--no-pager'], check=False)
        elif action == '6': change_secret(n, m)
        elif action == '7': delete(n, m)
        elif action == '8': force_repair(n, m)
    except (ValueError, OSError, sp.SubprocessError, configparser.Error) as e: print('操作未完成：' + str(e))
    except (KeyboardInterrupt, EOFError): print('\n已退出。'); break
PY
