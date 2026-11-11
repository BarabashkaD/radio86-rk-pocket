#!/usr/bin/env python3
"""Compiles Icarus testbenches here (the core's machine16 runner or the Pocket fpga/sim runner), runs the
.vvp files in the rk86-vvp container of this folder over ssh, and judges them with the runner's rules.
Nothing is simulated on this PC.

    python -B scripts/docker2tests/remote_sim.py --repo <root> [--host <docker host>] [--runner fork|pocket]
        [--port 2222] [--jobs 8] [--negative] [--mutant PATCH ...] [--mem FILE ...] [--iverilog PATH]
        [--timeout S] [--keep] TEST ...

--runner fork (default): --repo is the core's root (src/sim/machine16/run_machine16_sim.py); --mem
replaces the runner's TB memory file (one flag per file).
--runner pocket: --repo is the Pocket repo root (fpga/sim/run_sim.py; RK86_CORE_DIR selects the core
sources as for run_sim.py; a test with 'compare' runs fpga/sim/frame_compare.py locally on the fetched
frame).
--host defaults to RK86_VVP_HOST, --port to RK86_VVP_SSH_PORT (else 2222), --iverilog to IVERILOG.

The client key comes from RK86_VVP_KEY (the text the container prints, timestamps allowed); it is
written to a temporary folder for this run and deleted at the end. Never store the key in a file.
Compile from a tree nobody edits during the compile (a git worktree at the commit under test): a fault
being made by a temporary edit would otherwise end up in the run.
CPU slots: the container's CPUs (nproc) are shared. A run reserves min(--jobs, number of jobs) slots
(file /work/.rk86-slots/<run id>, stale after 12 h) under a short mkdir lock and waits (30 s polls)
until they fit. The old exclusive lock /work/.rk86-run.lock, if present and younger than 4 h, is
waited for. The run starts detached on the container (setsid nohup) and is polled once a minute, so
a dropped ssh session does not stop it; on --timeout, or when this script ends early, only this run's
process group is stopped. Each job has its own remote folder <run>/<jid>/ (cwd of the job); its log
and exit code go to <run>/<jid>.log and .rc. Logs, rc files and every file the job created are fetched
into <repo>/build/sim/remote16/<run id>/<jid>/out/ (the folder is removed at the end unless --keep).
Compile copies of patched files live in <jid>/copy/ of the same folder.
Pass rule: vvp exit 0, a line starting with PASS, no line starting with ERROR or containing FATAL
(for pocket then frame_compare, if the test has 'compare'). A fault is caught when its run fails and
the expected text is in its output (pocket, as run_sim.py) or in its first ERROR / FATAL line (fork, as
run_machine16_sim.py; anywhere in the output for an entry marked 'anywhere'; '*' matches any characters). A mutant is CAUGHT (first ERROR / FATAL line printed) or
SURVIVED; mutants do not change the exit code.
"""
import argparse
import concurrent.futures
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid

RUN_SH = r'''#!/bin/sh
# Runs every job of jobs.txt (jid and plusargs per line) with vvp, $1 at a time, each in its folder.
cd "$(dirname "$0")"
echo $$ > run.pid   # the session leader (setsid): its process group holds every job of this run
xargs -P "${1:-8}" -L 1 sh -c 'j=$0; cd "$j" && find . -type f | sort > "../$j.in"; vvp -n "$j.vvp" "$@" > "../$j.log" 2>&1; echo $? > "../$j.rc"' < jobs.txt
'''
OLD_LOCK = '/work/.rk86-run.lock'
ADMIT_LOCK = '/work/.rk86-admit.lock'
SLOTS = '/work/.rk86-slots'
STALE_MIN = 720   # a slot reservation older than this (min) is stale: the long system scenarios run for hours
# Prints OLD (old lock live), LOCKED (admission lock taken), GOT, or FULL <slots in use>.
ADMIT_SH = r'''L=@A@; S=@S@; O=@O@; mkdir -p $S
if [ -d $O ]; then
  if [ -n "$(find $O -maxdepth 0 -mmin +240)" ]; then rm -rf $O; else echo OLD; exit 0; fi
fi
[ -n "$(find $L -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir $L 2>/dev/null
if ! mkdir $L 2>/dev/null; then echo LOCKED; exit 0; fi
find $S -type f -mmin +@STALE@ -delete
rm -f $S/@R@   # this run's own claim from an attempt that timed out: not counted
sum=$(cat $S/* 2>/dev/null | awk '{s+=$2} END{print s+0}')
if [ $((sum + @W@)) -le @C@ ]; then echo "@R@ @W@ $(date +%s)" > $S/@R@; rmdir $L; echo GOT
else rmdir $L; echo FULL $sum; fi'''
# Stops this run's jobs only (its own process group), if any are still running.
KILL_SH = '[ -f {R}/run.pid ] && kill -- -$(cat {R}/run.pid) 2>/dev/null; true'
FETCH_SH = ('cd {R} && for r in *.rc; do j=${{r%.rc}}; (cd "$j" && find . -type f | grep -vxFf "../$j.in" '
            '| sed "s|^\\./|$j/|"); done > .fetch; tar -cf - -T .fetch *.log *.rc')


def key_block(text):
    m = re.findall(r'-----BEGIN OPENSSH PRIVATE KEY-----[\s\S]*?-----END OPENSSH PRIVATE KEY-----', text or '')
    if not m:
        return None
    out = []
    for line in m[-1].splitlines():
        line = line.strip()
        k = re.search(r'(-----(BEGIN|END) OPENSSH PRIVATE KEY-----)', line)
        if k:
            out.append(k.group(1))
        elif line:
            out.append(line.split()[-1])
    return '\n'.join(out) + '\n'


def rewrite_vvp(src, dst):
    """The .vvp rewrite contract of scripts/docker2tests/README.md (rules a-c)."""
    with open(src, encoding='latin-1', newline='') as f:
        lines = re.split(r'\r?\n', f.read())   # LF out, as test-remote.ps1 writes
    out, fn_left = [], 0   # entries of the :file_names list still to rewrite (one "..."; per line)
    for i, line in enumerate(lines):
        if i == 0 and line.startswith('#!'):
            continue
        if fn_left > 0:
            def base(m):
                v = m.group(1)
                return '"%s"' % (v if v == 'N/A' else re.split(r'[\\/]', v)[-1])
            fn_left -= len(re.findall(r'"[^"]*"', line))
            line = re.sub(r'"([^"]*)"', base, line)
            out.append(line)
            continue
        m = re.match(r'^:vpi_module\s+"([^"]*)"\s*;', line)
        if m:
            name = re.sub(r'\.vpi$', '', re.split(r'[\\/]', m.group(1))[-1])
            out.append(':vpi_module "%s";' % name)
            continue
        m = re.match(r'^:file_names\s+(\d+)\s*;', line)
        if m:
            fn_left = int(m.group(1))
        out.append(line)
    text = '\n'.join(out)
    if re.search(r'[A-Za-z]:[\\/]', text) or re.search(r'(?m)^/[a-z]/|"/[a-z]/', text):
        raise ValueError('%s: a local path is left after the rewrite' % dst)
    for v in ('USERPROFILE', 'HOME', 'USERNAME', 'USER', 'COMPUTERNAME', 'HOSTNAME'):   # README section 6
        s = os.environ.get(v, '')
        if len(s) >= 3 and s.lower() in text.lower():
            raise ValueError('%s: the %s of this PC is left after the rewrite' % (dst, v))
    with open(dst, 'w', encoding='latin-1', newline='') as f:
        f.write(text)


def load_runner(kind, repo):
    """Returns an object with tests, root, plus the hooks of the runner."""
    class RunnerInfo:
        pass
    r = RunnerInfo()
    r.kind = kind
    r.root = repo
    sys.dont_write_bytecode = True
    if kind == 'fork':
        sys.path.insert(0, os.path.join(repo, 'src', 'sim', 'machine16'))
        sys.path.insert(0, os.path.join(repo, 'src', 'sim'))
        import run_machine16_sim as R  # noqa: E402
        from negative import apply_patch, patched_files  # noqa: E402
        r.mod, r.tests, r.root = R, R.TESTS, R.ROOT
        r.neg_dir = os.path.join(R.ROOT, R.NEGATIVE_DIR)
    else:
        sys.path.insert(0, os.path.join(repo, 'fpga', 'sim'))
        import run_sim as R  # noqa: E402
        sys.path.insert(0, os.path.join(R.CORE, 'sim'))
        from negative import apply_patch, patched_files  # noqa: E402
        r.mod, r.tests, r.root = R, R.TESTS, R.ROOT
        r.neg_dir = R.NEG
    r.apply_patch, r.patched_files = apply_patch, patched_files
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--repo', required=True)
    ap.add_argument('--runner', choices=['fork', 'pocket'], default='fork')
    ap.add_argument('--host', default=os.environ.get('RK86_VVP_HOST'),
                    help='the Docker host (default: RK86_VVP_HOST)')
    ap.add_argument('--port', type=int, default=int(os.environ.get('RK86_VVP_SSH_PORT', '2222')))
    ap.add_argument('--user', default='sim')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--cap', type=int, default=0, help=argparse.SUPPRESS)   # test only: slot cap
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--mutant', action='append', default=[])
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--timeout', type=int, default=7200, help='limit of the remote run, s')
    ap.add_argument('--keep', action='store_true', help='keep the local build folder with the logs')
    ap.add_argument('--mem', action='append', default=[],
                    help='fork: a file compiled in place of the runner MEM (repeat the flag per file)')
    ap.add_argument('tests', nargs='+')
    a = ap.parse_args()

    if not a.host:
        print('ERROR: no host: pass --host or set RK86_VVP_HOST')
        return 2
    repo = os.path.abspath(a.repo)
    R = load_runner(a.runner, repo)
    pocket = a.runner == 'pocket'
    root = R.root

    unknown = [t for t in a.tests if t not in R.tests]
    if unknown:
        print('ERROR: unknown tests: %s' % ', '.join(unknown))
        return 2
    iverilog = shutil.which(a.iverilog)
    if not iverilog:
        print('ERROR: iverilog not found: %s' % a.iverilog)
        return 2
    env = dict(os.environ)
    env['PATH'] = os.path.dirname(iverilog) + os.pathsep + env.get('PATH', '')
    block = key_block(os.environ.get('RK86_VVP_KEY', ''))
    if not block:
        print('ERROR: no client key in RK86_VVP_KEY (copy it from the container console)')
        return 2

    t0 = time.time()
    run_id = 'm16-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
    build = os.path.join(repo, 'build', 'sim', 'remote16', run_id)
    os.makedirs(build)

    # The job list: (job, test name, kind, fault or patch, expected)
    jobs = []
    for name in a.tests:
        test = R.tests[name]
        jobs.append(('%s__main' % name, name, 'main', None, None))
        if a.negative:
            for entry in test.get('negatives', []):   # (fault, expected) or (fault, expected, 'anywhere')
                fault, expected = entry[0], entry[1]
                anywhere = pocket or (len(entry) > 2 and entry[2] == 'anywhere')
                jobs.append(('%s__f_%s' % (name, fault.replace('/', '_')), name, 'fault',
                             os.path.join(R.neg_dir, fault + '.patch'), (expected, anywhere)))
        for i, p in enumerate(a.mutant):
            jobs.append(('%s__m%02d' % (name, i), name, 'mutant', os.path.abspath(p), None))
    fault_name = {j[0]: j[3] and os.path.basename(j[3])[:-6] for j in jobs}
    if pocket:   # the Pocket runner prints the fault as written in TESTS (may hold a '/')
        for jid, name, kind, patch, _ in jobs:
            if kind == 'fault':
                fault_name[jid] = os.path.relpath(patch, R.neg_dir).replace('\\', '/')[:-6]

    hex_lock = threading.Lock()

    def compile_job(job):
        jid, name, kind, patch, _ = job
        test = R.tests[name]
        out = os.path.join(build, jid)
        os.makedirs(out)
        try:
            files = test['files']() if callable(test['files']) else list(test['files'])
            if a.mem and not pocket:
                files = [m for f in files for m in ([os.path.abspath(x) for x in a.mem] if f == R.mod.MEM else [f])]
            paths = [f if pocket else os.path.join(root, f) for f in files]
            if patch:
                copy_root = os.path.join(out, 'copy')
                fsrc = getattr(R.mod, 'fault_source', None) if pocket else None   # core files from RK86_CORE_DIR
                for rel in R.patched_files(patch):
                    src = fsrc(rel) if fsrc else os.path.join(root, rel)
                    idx = [i for i, p in enumerate(paths) if os.path.normcase(p) == os.path.normcase(src)]
                    if not idx:
                        if pocket:   # as run_sim.run(): copy and patch anyway
                            dst = os.path.join(copy_root, rel)
                            os.makedirs(os.path.dirname(dst), exist_ok=True)
                            shutil.copyfile(src, dst)
                            continue
                        return 'ERROR: %s is not compiled in this test' % rel
                    dst = os.path.join(copy_root, rel)
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copyfile(src, dst)
                    paths[idx[0]] = dst
                try:
                    R.apply_patch(root, copy_root, patch)
                except (ValueError, OSError) as e:
                    return 'ERROR: %s' % e
            top = test['top']
            if pocket:
                cart = test['cart']() if test.get('cart') else None
                if cart and not os.path.exists(cart):
                    return 'ERROR: %s missing: run python -B scripts/romdisk/build_romdisks.py' % cart
                extra = test['extra']() if test.get('extra') else []
                with hex_lock:
                    for h in test.get('hex', []):
                        R.mod.write_hex(h, out, cart if h == 'cartridge.hex' else None)
                    if test.get('inputs'):
                        test['inputs'](out)
                plus = list(test.get('plusargs', [])) + extra
                incdirs = [os.path.join(root, 'fpga', 'rtl'), os.path.join(root, 'fpga', 'sim', 'system')]
                incdirs += test['incdirs']() if test.get('incdirs') else []   # as run_sim.run()
                cmd_head = [iverilog, '-g2012'] + [x for d in incdirs for x in ('-I', d)] + ['-s', top]
                cmd_tail = []
            else:
                plus = ['+%s=%s' % (k, v) for k, v in test.get('plusargs', {}).items()]
                hx = getattr(R.mod, 'write_hexfiles', None)
                if hx:
                    made = hx(test, out, prefix='')
                    plus += ['+%s=%s' % (k, v) for k, v in made.items()]
                cmd_head = [iverilog, '-g2005', '-s', top]
                cmd_tail = ['-P%s.%s=%s' % (top, k, v) for k, v in sorted(test.get('params', {}).items())]
            raw = os.path.join(out, 'raw.vvp')
            res = subprocess.run(cmd_head + ['-o', raw] + cmd_tail + paths,
                                 capture_output=True, text=True, cwd=out, env=env)
            if res.returncode:
                return 'ERROR: iverilog: ' + res.stdout + res.stderr
            rewrite_vvp(raw, os.path.join(out, jid + '.vvp'))
            plus_of[jid] = plus
            return None
        except (ValueError, OSError, SystemExit) as e:
            return 'ERROR: %s' % e

    plus_of = {}
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        cerr = dict(zip([j[0] for j in jobs], ex.map(compile_job, jobs)))
    t_compile = time.time() - t0
    for j, e in cerr.items():
        if e:
            print('%s: compile failed: %s' % (j, e.strip()[:400]))
    runnable = [j for j in jobs if not cerr[j[0]]]

    with open(os.path.join(build, 'jobs.txt'), 'w', newline='\n') as f:
        for jid, *_ in runnable:
            f.write(' '.join([jid] + plus_of[jid]) + '\n')
    with open(os.path.join(build, 'run.sh'), 'w', newline='\n') as f:
        f.write(RUN_SH)

    # The upload: run.sh, jobs.txt and, per job, its folder without raw.vvp and copy/.
    up_names = ['run.sh', 'jobs.txt']
    for jid, *_ in runnable:
        for d, dirs, fs in os.walk(os.path.join(build, jid)):
            if d == os.path.join(build, jid):
                dirs[:] = [x for x in dirs if x not in ('copy', 'out')]
            for fn in fs:
                if d == os.path.join(build, jid) and fn == 'raw.vvp':
                    continue
                up_names.append(os.path.relpath(os.path.join(d, fn), build).replace('\\', '/'))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        for n in up_names:
            ti = tf.gettarinfo(os.path.join(build, n), arcname=n)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ''
            ti.mode = 0o755 if n == 'run.sh' else 0o644
            with open(os.path.join(build, n), 'rb') as fh:
                tf.addfile(ti, fh)
    upload = buf.getvalue()

    width = max(1, min(a.jobs, len(runnable)))
    tmp = tempfile.mkdtemp(prefix='rk86-vvp-')
    results, fetched = {}, []
    reserved = [False]
    rdir = '/work/' + run_id
    remote_ok = False
    try:
        key = os.path.join(tmp, 'client_ed25519')
        with open(key, 'w', newline='\n') as f:
            f.write(block)
        if os.name == 'nt':
            sid = subprocess.run(['powershell', '-NoProfile', '-Command',
                                  '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'],
                                 capture_output=True, text=True).stdout.strip()
            subprocess.run(['icacls', key, '/inheritance:r', '/grant:r', '*%s:F' % sid], capture_output=True)
        known = os.path.join(tmp, 'known_hosts').replace('\\', '/')
        opts = ['-i', key.replace('\\', '/'), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'LogLevel=ERROR',
                '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=' + known]
        remote = '%s@%s' % (a.user, a.host)

        def ssh(cmd, timeout, binary=False, data=None, tries=4):
            # a busy container answers slowly: retry a command that timed out (every caller's command
            # is safe to repeat, except the start, which passes tries=1 and checks run.pid itself)
            for n in range(tries):
                try:
                    return subprocess.run(['ssh'] + opts + ['-p', str(a.port), remote, cmd],
                                          capture_output=True, timeout=timeout, text=not binary, input=data)
                except subprocess.TimeoutExpired:
                    if n == tries - 1:
                        raise
                    print('ssh: no answer in %d s, again in 30 s' % timeout, flush=True)
                    time.sleep(30)

        if not runnable:
            print('ERROR: nothing to run')
            return 1
        r = ssh('nproc', 60)
        if r.returncode:
            print('ERROR: ssh: %s' % (r.stderr or r.stdout).strip())
            return 1
        ncpu = int(r.stdout.split()[0])
        cap = a.cap or ncpu
        width = min(width, cap)
        script = (ADMIT_SH.replace('@A@', ADMIT_LOCK).replace('@S@', SLOTS).replace('@O@', OLD_LOCK)
                  .replace('@W@', str(width)).replace('@C@', str(cap)).replace('@R@', run_id)
                  .replace('@STALE@', str(STALE_MIN)))
        waited = None
        while True:
            r = ssh('sh -s', 60, binary=True, data=script.encode())
            ans = r.stdout.decode().strip() if r.returncode == 0 else ''
            if ans == 'GOT':
                reserved[0] = True
                break
            if waited is None:
                waited = time.time()
                if ans.startswith('FULL'):
                    print('waiting for %d free CPU slots (%s in use)' % (width, ans.split()[1]), flush=True)
                elif ans == 'OLD':
                    print('waiting for the container: an old-style run holds the exclusive lock', flush=True)
                else:
                    print('waiting for the container (%s)' % (ans or r.stderr.decode(errors='replace').strip()), flush=True)
            if ans == 'LOCKED':
                time.sleep(2)
            else:
                time.sleep(30)
        if waited is not None:
            print('slots free after %.0f s' % (time.time() - waited))
        print('remote %s: %d CPUs, %d jobs, %d at a time' % (a.host, ncpu, len(runnable), width))
        t1 = time.time()
        r = ssh('mkdir -p %s && tar -xf - -C %s' % (rdir, rdir), 600, binary=True, data=upload)
        remote_ok = True
        if r.returncode:
            print('ERROR: upload: %s' % r.stderr.decode(errors='replace').strip())
            return 1
        t_up = time.time() - t1
        t2 = time.time()
        # detached: a dropped ssh session does not kill a run of several hours; polled once a minute
        # the background job alone, all three streams redirected, so the ssh channel closes at once
        # a busy container can hold the channel past the timeout although the run started: then check run.pid
        try:
            r = ssh('cd %s || exit 1; (setsid nohup sh run.sh %d > run.out 2>&1 < /dev/null &); echo started' % (rdir, width), 120,
                    tries=1)
            started, why = not r.returncode and 'started' in (r.stdout or ''), (r.stderr or r.stdout or '').strip()
        except subprocess.TimeoutExpired:
            started, why = False, 'no answer in 120 s'
        for _ in range(5 if not started else 0):
            time.sleep(20)
            try:
                p = ssh('[ -s %s/run.pid ] && echo started' % rdir, 60)
            except subprocess.TimeoutExpired:
                continue
            if 'started' in (p.stdout or ''):
                print('start: %s; run.pid found, the run started' % why)
                started = True
                break
        if not started:
            print('ERROR: start: %s' % why)
            return 1
        njobs = len(runnable)
        while True:
            time.sleep(60)
            try:
                p = ssh('ls %s/*.rc 2>/dev/null | wc -l' % rdir, 60)
                done = int((p.stdout or '0').split()[0]) if p.returncode == 0 else -1
            except (subprocess.TimeoutExpired, ValueError, IndexError):
                done = -1
            if done >= njobs:
                break
            if time.time() - t2 > a.timeout:
                print('ERROR: remote run over --timeout %d s (%s of %d jobs done); killing it' % (a.timeout, done, njobs))
                ssh(KILL_SH.format(R=rdir), 60)
                break
        t_run = time.time() - t2
        r = ssh('sh -s', 600, binary=True, data=FETCH_SH.format(R=rdir).encode())
        if r.returncode:
            print('ERROR: fetching the logs: %s' % r.stderr.decode(errors='replace').strip())
            return 1
        with tarfile.open(fileobj=io.BytesIO(r.stdout)) as tf:
            for m in tf.getmembers():
                if not m.isfile():
                    continue
                parts = m.name.split('/')
                if m.name.startswith('/') or '..' in parts:
                    continue
                jid = parts[0][:-4] if len(parts) == 1 else parts[0]
                rel = parts[0] if len(parts) == 1 else '/'.join(parts[1:])
                dst = os.path.join(build, jid, 'out', *rel.split('/'))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                data = tf.extractfile(m).read()
                with open(dst, 'wb') as fh:
                    fh.write(data)
                if len(parts) == 1:
                    results[m.name] = data.decode('utf-8', errors='replace')
    finally:
        try:
            if remote_ok:
                ssh(KILL_SH.format(R=rdir) + '; rm -rf ' + rdir, 60)
            if reserved[0]:
                ssh('rm -f %s/%s' % (SLOTS, run_id), 60)
        except Exception:
            pass
        shutil.rmtree(tmp, ignore_errors=True)

    failed = 0
    for jid, name, kind, patch, expected in jobs:
        if cerr[jid]:
            failed += 1
            continue
        text = results.get(jid + '.log', '')
        rc = results.get(jid + '.rc', '').strip()
        lines = [l.strip() for l in text.splitlines()]
        ok = (rc == '0' and any(l.startswith('PASS') for l in lines)
              and not any(l.startswith('ERROR') or 'FATAL' in l for l in lines))
        first = next((l for l in lines if l.startswith('ERROR') or 'FATAL' in l), '')
        test = R.tests[name]
        if pocket and ok and test.get('compare'):
            produced, golden = test['compare']
            cmp = subprocess.run([sys.executable, '-B', os.path.join(root, 'fpga', 'sim', 'frame_compare.py'),
                                  os.path.join(build, jid, 'out', produced), os.path.join(root, golden)],
                                 capture_output=True, text=True)
            text += cmp.stdout + cmp.stderr
            ok = cmp.returncode == 0
            first = first or next((l.strip() for l in text.splitlines() if l.strip()), '')
        if kind == 'main':
            print('%s: %s' % (name, 'PASS' if ok else 'FAIL'))
            if not ok:
                print(text.rstrip()[-3000:])
                failed += 1
        elif kind == 'fault':
            want, anywhere = expected
            contains = getattr(R.mod, 'contains', None) or (lambda s, e: e in s)
            caught = (not ok) and contains(text if anywhere else first, want)
            print('%s: negative %s %s' % (name, fault_name[jid], 'FAILED as expected' if caught else
                                          'NOT CAUGHT (expected%s: %s)' % (' anywhere' if anywhere else '', want)))
            if not caught:
                print('  first error: %s' % (first or '(none)'))
                failed += 1
        else:
            print('%s: mutant %s %s' % (name, os.path.basename(patch),
                                        'CAUGHT: ' + first if not ok else 'SURVIVED'))
    print('times: compile %.0f s, upload %.0f s, remote run %.0f s, total %.0f s'
          % (t_compile, t_up, t_run, time.time() - t0))
    if a.keep:
        print('logs and job outputs kept in %s (<jid>/out/)' % build)
    else:
        shutil.rmtree(build, ignore_errors=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
