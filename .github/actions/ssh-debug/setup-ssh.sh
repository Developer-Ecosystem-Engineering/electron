#!/bin/bash -e
#
# GNU Bash required for process substitution `<()` later.
#
# Environment variables:
#
# - `GITHUB_ACTION_PATH`: path to this repository.
# - `GITHUB_ACTOR`: GitHub username of whoever triggered the action.
# - `GITHUB_WORKSPACE`: default path for the workflow (the tmux session will start there).
#

notify_func() {
    cat
}

get_authorized_keys() {
    case "$GITHUB_ACTOR" in
        codebytere|MarshallOfSound|jkleinsc|vertedinde)
            ;;
        *)
            echo ""
            return 1
            ;;
    esac

    api_response=$(curl -s "https://api.github.com/users/$GITHUB_ACTOR/keys")

    if echo "$api_response" | jq -e 'type == "object" and has("message")' >/dev/null; then
        error_msg=$(echo "$api_response" | jq -r '.message')
        echo "Error: $error_msg"
        exit 1
    else
        echo "$api_response" | jq -r '.[].key' > authorized_keys
    fi
}

# Check if user is authorized.
authorized_keys=$(get_authorized_keys "$GITHUB_ACTOR")
if [ -z "$authorized_keys" ]; then
    echo "Error: User '$GITHUB_ACTOR' is not authorized to access this debug session."
    echo "Only @electron/wg-infra team members are allowed."
    exit 1
fi

echo "Authorized @electron/wg-infra member: $GITHUB_ACTOR"

EXTERNAL_DEPS="curl jq ssh-keygen"

for dep in $EXTERNAL_DEPS; do
    if ! command -v "$dep" > /dev/null 2>&1; then
       echo "Command $dep not installed on the system!" >&2
       exit 1
    fi
done

cd "$GITHUB_ACTION_PATH"

bashrc_path=$(pwd)/bashrc

#
# Source our `bashrc` to auto start tmux upon SSH login.
#
# Added to `~/.bash_profile` because at least on GitHub default runner, there's
# both a `~/.bash_profile` that sets up `nvm`, and a `~/.profile` that sources
# `~/.bashrc` if interactive, but Bash will only source `~/.bash_profile` if it
# exists, so in a GitHub runner, `~/.bashrc` will never be sourced when using a
# login shell like over SSH (but it will if starting a sub non-login shell by
# typing `bash`).
#
# So we hook into `~/.bash_profile` instead.
#
if ! grep -q "$bashrc_path" ~/.bash_profile; then
    echo >> ~/.bash_profile # On macOS runner there's no newline at the end of the file
    echo "source \"$bashrc_path\"" >> ~/.bash_profile
fi

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Install tmux on macOS runners if not present.
if [ "$OS" = "darwin" ] && ! command -v tmux > /dev/null 2>&1; then
    echo "Installing tmux..."
    brew install tmux
fi

if [ "$OS" = "darwin" ]; then
    cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${OS}-${ARCH}.tgz"
    echo "Downloading \`cloudflared\` from <$cloudflared_url>..."
    curl --location --silent --output cloudflared.tgz "$cloudflared_url"
    tar xf cloudflared.tgz
    rm cloudflared.tgz
else
    cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${OS}-${ARCH}"
    echo "Downloading \`cloudflared\` from <$cloudflared_url>..."
    curl --location --silent --output cloudflared "$cloudflared_url"
fi

chmod +x cloudflared

echo "Setting up SSH key for authorized user: $GITHUB_ACTOR"
echo "$authorized_keys" > authorized_keys

echo 'Creating SSH server key...'
ssh-keygen -q -f ssh_host_rsa_key -N ''

echo 'Creating SSH server config...'
sed "s,\$PWD,$PWD,;s,\$USER,$USER," sshd_config.template > sshd_config

echo 'Starting SSH server...'
/usr/sbin/sshd -f sshd_config -D &
sshd_pid=$!

echo 'Starting tmux session...'
(cd "$GITHUB_WORKSPACE" && tmux new-session -d -s debug)

echo 'Starting Cloudflare tunnel...'
./cloudflared tunnel --no-autoupdate --url tcp://localhost:2222 2>&1 | tee cloudflared.log | sed -u 's/^/cloudflared: /' &
cloudflared_pid=$!

url=$(head -1 <(tail -f cloudflared.log | grep --line-buffered -o 'https://.*\.trycloudflare.com'))

# Ignore the `user@host` part at the end of the public key.
public_key=$(cut -d' ' -f1,2 < ssh_host_rsa_key.pub)

(
    echo '    '
    echo '    '
    echo '    '
    echo '    '
    echo 'Run the following command to connect:'
    echo '    '
    echo "    ssh-keygen -R action-sshd-cloudflared && echo 'action-sshd-cloudflared $public_key' >> ~/.ssh/known_hosts && ssh -o ProxyCommand='cloudflared access tcp --hostname $url' runner@action-sshd-cloudflared"
) | notify_func

echo 'Starting SSH session in background...'
./ssh-session.sh "$sshd_pid" "$cloudflared_pid" &

echo 'Session ended'

kill "$cloudflared_pid"
kill "$sshd_pid"
