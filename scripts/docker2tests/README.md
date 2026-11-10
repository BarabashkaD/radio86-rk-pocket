# rk86-vvp: run compiled Icarus Verilog files over SSH

## 1. Purpose

Test benches are compiled on a Windows PC with Icarus Verilog 13.0. The
compiled `.vvp` files run in a Docker container (Icarus 13.0 runtime plus an
SSH server) on any machine in the local network.

```
Windows PC                                   Docker host (container rk86-vvp)
iverilog -> x.vvp -> rewrite (section 6)
  scp x.vvp  ------------------------------> /work/<run>/x.vvp
  ssh "cd /work/<run> && vvp -n x.vvp > x.log 2>&1" -> vvp runs as user sim
  scp x.log  <------------------------------ /work/<run>/x.log
```

Access is by key only. The container makes its own key pair at the first start
and keeps it in its volume; it prints the client private key on its console at
every start. The PC takes that key for one run, writes it to a temporary file
and deletes it at the end: no key is saved on the PC or in the repository. The
network is assumed to be a trusted local one.

## 2. Install

**The PC (client, Windows):**
- Icarus Verilog 13.0, e.g. MSYS2 `pacman -S mingw-w64-ucrt-x86_64-iverilog`;
  pass `-Iverilog` or set `IVERILOG`.
- The built-in OpenSSH client (`ssh`, `scp`, `ssh-keygen`; Windows 10/11
  optional feature "OpenSSH Client").

**The Docker host** (this PC or another machine in the LAN):
- Windows: Docker Desktop. Linux: Docker Engine with the Compose plugin, e.g.
  Debian/Ubuntu `docker-ce` + `docker-compose-plugin` from Docker's apt
  repository; add your user to the `docker` group (log out and in once).
- Inbound TCP on the published port (default 2222) when clients connect from
  other machines (section 5).

**Steps:**
1. Copy this folder to the Docker host if it is another machine (it holds no
   key).
2. On the Docker host, in this folder: `docker compose build --progress=plain`
   (the log ends with `SELFTEST OK`), then `docker compose up -d`.
3. Open the container's console: Docker Desktop, Containers, `rk86-vvp`, Logs;
   or `docker compose logs rk86-vvp`. Between the lines
   `==== rk86-vvp client key ... ====` is the private key. Copy the lines from
   `-----BEGIN OPENSSH PRIVATE KEY-----` to `-----END OPENSSH PRIVATE KEY-----`.
   Text copied from Docker Desktop's log view, with a timestamp on each line,
   is accepted as it is.
4. On the PC, in this folder: `.\test-remote.ps1 -SshHost <docker-host-lan-ip>`.
   It reads the key from the clipboard (or from `-KeyText` / `RK86_VVP_KEY`).
   When the container runs on this PC, step 3 is not needed: the script reads
   the key from the local console log, and `-SshHost` can be left out. It must
   print `REMOTE TEST OK`.

The key stays the same while the volume exists. `docker compose down -v` deletes
it; the next start makes a new one, which then has to be copied again.

## 3. The version rule

The compiler (PC) and the runtime (container) must both be Icarus Verilog
13.0. Compare the number only (`version 13.0`); the "(stable)" / "(devel)"
text may differ between MSYS2 and Debian. The image self-test and
`test-remote.ps1` both check it.

## 4. Build and start

```
docker compose build --progress=plain     # the log ends with SELFTEST OK
docker compose up -d                      # prints the client key on its console
docker compose logs rk86-vvp              # shows the console again
docker compose stop / start               # keeps /work
docker compose down                       # drops /work, keeps the keys
docker compose down -v                    # drops the keys too (a new key next start)
docker compose run --rm rk86-vvp selftest
```

`RK86_VVP_SSH_PORT` changes the published port
(default 2222). To keep `/work` on the host, enable the commented bind mount
(source `./work`, target `/work`) in `compose.yaml`; make the folder writable
for uid 1000. The base image is the build argument `BASE_IMAGE`.

## 5. The test script

```
.\test-remote.ps1 [-SshHost localhost] [-Port 2222] [-User sim] [-KeyText <key lines>]
                  [-Iverilog <path to iverilog>] [-TimeoutSec 60]
```

`-Iverilog` defaults to the `IVERILOG` environment variable, else `iverilog` on
PATH (`vvp` is taken from the same folder). `-Port` defaults to
`RK86_VVP_SSH_PORT`, else 2222. It works in Windows PowerShell 5.1 and in
PowerShell 7. It compiles `hello.v`, rewrites the `.vvp`, runs it locally and
in the container, compares both outputs and prints `REMOTE TEST OK` with the
time of each step.

To use another machine, pass its LAN address as `-SshHost <lan-ip>`. That
machine must allow inbound TCP on the port: on Windows a Private-profile
inbound rule for the port (or an allow for the Docker backend); on Linux an
`ufw allow <port>/tcp` or the equivalent firewalld/nftables rule. A connection
from a PC to its own LAN address does not prove that other machines can reach it.

The batch client should cap its own number of parallel `ssh` / `scp`
connections (Windows OpenSSH opens a new connection each time; sshd is set to
`MaxStartups 100:30:200`, `MaxSessions 100`).

## 6. The `.vvp` rewrite contract

Before copying, the PC rewrites the compiled file so it holds no local paths:

- a. `:vpi_module "<anything>/<name>.vpi";` (also the `\` form) becomes
  `:vpi_module "<name>";`.
- b. the N entries after `:file_names N;` (one `"...";` per line, so the list
  ends after N strings, not at the first `;`) become their bare file names,
  except vvp's own placeholder `"N/A"`, which stays as it is. `N` and the
  number of strings stay equal.
- c. a `#!` first line is removed.
- d. `:ivl_version` is left as it is (vvp does not check it).

Then the file is checked for drive-letter paths, MSYS2 paths
(`/c/...`), and the user profile path, user name and computer name of the PC.

Run folder convention: `/work/<run>/<name>.vvp` and `/work/<run>/<name>.log`
side by side, owned by `sim`. Run with `vvp -n <name>.vvp > <name>.log 2>&1`.

## 7. The package pin

The Dockerfile installs `iverilog=13.0-2` exactly. A later rebuild gets that
package or fails loudly (the base tag is dated, the apt index is not). Check
what is available with `apt-cache madison iverilog` in the container. For a
fully frozen index, point apt at `snapshot.debian.org`.

## 8. Moving the image

`docker save rk86-vvp:13.0 | ssh <host> docker load` (or save to a file and
`docker load -i`), or copy this folder to the other host and run
`docker compose build` there.

## 9. Troubleshooting

- `no client key`: copy the key lines from the container's console (Install,
  step 3) and run again.
- `Permission denied (publickey)` after `down -v`: the container made a new key;
  copy it again from its console.
- `the key text is not a usable private key`: the copied text is incomplete;
  copy all lines from `BEGIN` to `END`.
- Port already in use: set `RK86_VVP_SSH_PORT` to a free port (and pass `-Port`).
