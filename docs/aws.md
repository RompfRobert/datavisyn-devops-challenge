# AWS CLI Install and Configuration

This guide covers the installation and basic configuration of the **AWS CLI (v2)** for macOS and Linux (including WSL).

## 1. Installation

### macOS (GUI or PKG)

The most reliable way on macOS is using the official installer.

1. **Download and install:**

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

1. **Verify:**

```bash
aws --version
```

### Linux / WSL (x86_64)

For Ubuntu, Fedora, or WSL, use the bundled installer.

1. **Download and Extract:**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
```

1. **Install:**

```bash
sudo ./aws/install
```

1. **Verify:**

```bash
aws --version
```

> **Note:** If you are using an ARM-based Linux instance (like Graviton), replace `x86_64` with `aarch64` in the URL.

## 2. Configuration

Once installed, you need to link the CLI to your AWS account.

### Quick Setup

Run the following command:

```bash
aws configure
```

You will be prompted for four pieces of information:

1. **AWS Access Key ID:** Your IAM user identifier.
2. **AWS Secret Access Key:** Your IAM user secret.
3. **Default region name:** e.g., `us-east-1` or `eu-central-1`.
4. **Default output format:** `json` (recommended), `text`, or `table`.

### Configuration Files

The CLI stores these settings in your home directory:

* `~/.aws/credentials`: Stores sensitive Access Keys.
* `~/.aws/config`: Stores regions and output formats.

## 3. Pro-Tips for Linux & macOS

### Enable Auto-Completion

To enable command completion (tabbing), add this to your `.bashrc` or `.zshrc`:

```bash
# For Zsh (macOS default)
echo "source /usr/local/bin/aws_zsh_completer.sh" >> ~/.zshrc

# For Bash (Linux default)
echo "complete -C '/usr/local/bin/aws_completer' aws" >> ~/.bashrc
```

### Named Profiles

If you manage multiple accounts, use profiles to avoid overwriting your main credentials:

```bash
aws configure --profile work-account
# Usage:
aws s3 ls --profile work-account```
