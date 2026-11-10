ARG BASE_IMAGE=debian:testing-20261104-slim
FROM ${BASE_IMAGE}

# Exact package pin: a rebuild gets this iverilog or fails loudly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends iverilog=13.0-2 python3 openssh-server \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -U -s /bin/bash sim \
 && usermod -p '*' sim \
 && mkdir -p /work \
 && chown sim:sim /work

RUN printf '%s\n' \
    'HostKey /etc/ssh/keys/ssh_host_ed25519_key' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'AllowUsers sim' \
    'UseDNS no' \
    'MaxStartups 100:30:200' \
    'MaxSessions 100' \
    > /etc/ssh/sshd_config.d/rk86-vvp.conf

# Build-time check of the sshd configuration with a throwaway host key.
# /etc/ssh/keys must stay empty in the image (a named volume copies it).
RUN mkdir -p /run/sshd /etc/ssh/keys \
 && ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/keys/ssh_host_ed25519_key \
 && /usr/sbin/sshd -t \
 && rm -f /etc/ssh/keys/ssh_host_ed25519_key /etc/ssh/keys/ssh_host_ed25519_key.pub

COPY entrypoint.sh selftest.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/selftest.sh \
 && ln -s selftest.sh /usr/local/bin/selftest \
 && selftest \
 && dpkg-query -W -f='iverilog package version: ${Version}\n' iverilog

WORKDIR /work
EXPOSE 22
ENTRYPOINT ["entrypoint.sh"]
CMD ["sshd"]
