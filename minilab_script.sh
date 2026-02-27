#!/bin/bash
# hpc_minilab.sh (patched)
# Fixes common "network is unreachable" Docker pulls (IPv6 issues) by forcing IPv4/DNS.
# Also keeps LAB_DIR under the invoking user's HOME even when run via sudo.

set -euo pipefail

# Preserve the real user when run under sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
LAB_DIR="${REAL_HOME}/hpc-lab"
ANS_DIR="${LAB_DIR}/ansible"
IMG_DIR="${LAB_DIR}/node_image"
SHARED_DIR="${LAB_DIR}/shared"

need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

echo "==> [1/10] Checking/Installing prerequisites..."
if need_cmd apt-get; then
  sudo apt-get update -y
  sudo apt-get install -y docker.io docker-compose ansible openssh-client
else
  echo "ERROR: apt-get not found. This script expects Debian/Ubuntu."
  exit 1
fi

# Ensure docker is running
if need_cmd systemctl; then
  sudo systemctl enable --now docker || true
else
  sudo service docker start || true
fi

# Determine docker compose command
DOCKER_COMPOSE=""
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif need_cmd docker-compose; then
  DOCKER_COMPOSE="docker-compose"
else
  echo "ERROR: neither 'docker compose' nor 'docker-compose' is available."
  exit 1
fi

echo "==> [2/10] Ensuring Docker can pull images (IPv4/DNS workaround if needed)..."
# Try a pull; if it fails with IPv6-like errors, apply daemon.json workaround
set +e
PULL_OUT="$(docker pull ubuntu:22.04 2>&1)"
PULL_RC=$?
set -e

if [ $PULL_RC -ne 0 ]; then
  echo "==> Docker pull failed. Applying IPv4/DNS workaround in /etc/docker/daemon.json ..."
  sudo mkdir -p /etc/docker
  sudo bash -c 'cat > /etc/docker/daemon.json <<EOF
{
  "ipv6": false,
  "dns": ["1.1.1.1", "8.8.8.8"]
}
EOF'

  if need_cmd systemctl; then
    sudo systemctl restart docker
  else
    sudo service docker restart || true
  fi

  echo "==> Retrying docker pull ubuntu:22.04 ..."
  docker pull ubuntu:22.04
fi

echo "==> [3/10] Creating lab directory structure at: ${LAB_DIR}"
mkdir -p "${ANS_DIR}" "${IMG_DIR}" "${SHARED_DIR}"

echo "==> [4/10] Writing Docker node image (sshd + sudo + python3)..."
cat > "${IMG_DIR}/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server sudo python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd

RUN useradd -m -s /bin/bash ansible \
    && echo "ansible ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/ansible \
    && chmod 440 /etc/sudoers.d/ansible

RUN sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
 && sed -i 's/^UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd","-D","-e"]
DOCKERFILE

echo "==> [5/10] Writing docker compose cluster (head + compute1 + compute2)..."
cat > "${LAB_DIR}/compose.yml" <<'YAML'
services:
  head:
    build: ./node_image
    container_name: hpc-head
    hostname: head
    ports:
      - "2221:22"
    volumes:
      - ./shared:/shared

  compute1:
    build: ./node_image
    container_name: hpc-compute1
    hostname: compute1
    ports:
      - "2222:22"
    volumes:
      - ./shared:/shared

  compute2:
    build: ./node_image
    container_name: hpc-compute2
    hostname: compute2
    ports:
      - "2223:22"
    volumes:
      - ./shared:/shared
YAML

echo "==> [6/10] Writing Ansible config + inventory..."
cat > "${ANS_DIR}/ansible.cfg" <<'CFG'
[defaults]
inventory = inventory.ini
host_key_checking = False
retry_files_enabled = False
timeout = 30
interpreter_python = auto
CFG

cat > "${ANS_DIR}/inventory.ini" <<'INV'
[head]
head ansible_host=127.0.0.1 ansible_port=2221 ansible_user=ansible

[compute]
compute1 ansible_host=127.0.0.1 ansible_port=2222 ansible_user=ansible
compute2 ansible_host=127.0.0.1 ansible_port=2223 ansible_user=ansible

[cluster:children]
head
compute
INV

echo "==> [7/10] Writing Ansible playbook..."
cat > "${ANS_DIR}/hpc.yml" <<'PLAY'
---
- name: HPC mini-lab (MPI over SSH) - base packages
  hosts: cluster
  become: yes

  vars:
    mpi_packages:
      - build-essential
      - openmpi-bin
      - libopenmpi-dev
      - openssh-client
      - openssh-server

  tasks:
    - name: Install MPI toolchain and SSH
      apt:
        update_cache: yes
        name: "{{ mpi_packages }}"
        state: present

    - name: Create mpi user
      user:
        name: mpi
        shell: /bin/bash
        create_home: yes

    - name: Allow mpi passwordless sudo (demo convenience)
      copy:
        dest: /etc/sudoers.d/mpi
        content: "mpi ALL=(ALL) NOPASSWD:ALL\n"
        mode: "0440"

    - name: Ensure /shared exists (bind-mounted)
      file:
        path: /shared
        state: directory
        mode: "0777"

- name: Configure key-based SSH for MPI (head -> all)
  hosts: head
  become: yes

  tasks:
    - name: Ensure mpi has .ssh
      file:
        path: /home/mpi/.ssh
        state: directory
        owner: mpi
        group: mpi
        mode: "0700"

    - name: Generate SSH key for mpi on head (if missing)
      command: sudo -u mpi ssh-keygen -t ed25519 -N "" -f /home/mpi/.ssh/id_ed25519
      args:
        creates: /home/mpi/.ssh/id_ed25519

    - name: Read mpi public key
      slurp:
        src: /home/mpi/.ssh/id_ed25519.pub
      register: mpi_pub

    - name: Write cluster hostfile for MPI
      copy:
        dest: /shared/hostfile
        content: |
          compute1 slots=1
          compute2 slots=1
        mode: "0644"

    - name: Write MPI hello program (C)
      copy:
        dest: /shared/mpi_hello.c
        content: |
          #include <mpi.h>
          #include <stdio.h>
          int main(int argc, char** argv) {
            MPI_Init(&argc, &argv);
            int rank, size;
            MPI_Comm_rank(MPI_COMM_WORLD, &rank);
            MPI_Comm_size(MPI_COMM_WORLD, &size);
            char name[MPI_MAX_PROCESSOR_NAME];
            int len = 0;
            MPI_Get_processor_name(name, &len);
            printf("Hello from rank %d of %d on %s\n", rank, size, name);
            MPI_Finalize();
            return 0;
          }

    - name: Compile MPI program on head into /shared
      command: mpicc /shared/mpi_hello.c -O2 -o /shared/mpi_hello
      args:
        creates: /shared/mpi_hello

- name: Authorize head mpi key on all nodes
  hosts: cluster
  become: yes

  tasks:
    - name: Ensure mpi has .ssh
      file:
        path: /home/mpi/.ssh
        state: directory
        owner: mpi
        group: mpi
        mode: "0700"

    - name: Add head mpi public key to authorized_keys
      authorized_key:
        user: mpi
        key: "{{ hostvars['head'].mpi_pub.content | b64decode }}"
        state: present

    - name: Disable StrictHostKeyChecking for mpi (demo convenience)
      copy:
        dest: /home/mpi/.ssh/config
        owner: mpi
        group: mpi
        mode: "0600"
        content: |
          Host *
            StrictHostKeyChecking no
            UserKnownHostsFile=/dev/null
PLAY

echo "==> [8/10] Building and starting the cluster containers..."
cd "${LAB_DIR}"
${DOCKER_COMPOSE} -f compose.yml up -d --build

echo "==> Waiting briefly for sshd to come up on nodes..."
sleep 2

echo "==> [9/10] Setting up SSH key on THIS machine for Ansible -> containers..."
sudo -u "${REAL_USER}" mkdir -p "${REAL_HOME}/.ssh"
if [ ! -f "${REAL_HOME}/.ssh/id_ed25519" ]; then
  sudo -u "${REAL_USER}" ssh-keygen -t ed25519 -N "" -f "${REAL_HOME}/.ssh/id_ed25519"
fi

echo "==> Installing your public key into each container's ansible account..."
for p in 2221 2222 2223; do
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$p" ansible@127.0.0.1 \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  cat "${REAL_HOME}/.ssh/id_ed25519.pub" | \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$p" ansible@127.0.0.1 \
    "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
done

echo "==> Sanity: Ansible ping all nodes..."
cd "${ANS_DIR}"
ansible all -m ping

echo "==> [10/10] Running the Ansible HPC provisioning playbook..."
ansible-playbook hpc.yml

echo
echo "==> Running MPI test across compute nodes (from head)..."
cd "${LAB_DIR}"
docker exec -it hpc-head bash -lc \
  "sudo -u mpi bash -lc 'mpirun --hostfile /shared/hostfile -np 2 /shared/mpi_hello'"

echo
echo "==> SUCCESS: HPC mini-lab built, provisioned, and MPI job executed."
echo "    Lab folder: ${LAB_DIR}"
echo "    To stop:    cd ${LAB_DIR} && ${DOCKER_COMPOSE} -f compose.yml down"
