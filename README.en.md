# Realm-Manager

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![Version](https://img.shields.io/badge/version-v0.1.4-blue?style=flat-square)

[中文](README.md) | **English**

**Realm forwarding management script.**

> Designed for Debian / Ubuntu root environments. The short install URL is the preferred entry point.

---

## 🎯 Features

- Install / update Realm
- Add, list and delete forwarding rules
- systemd service management
- Optional daily restart via cron

---

## 🚀 Quick Start

```bash
bash <(curl -Ls https://realm.shuijiao.de)
```

---

## ⚙️ Versioning and Releases

- Current version: `v0.1.3`
- Changelog: [`CHANGELOG.md`](CHANGELOG.md)
- GitHub Releases are generated from `CHANGELOG.md`
- Maintainers can publish a new version with:

```bash
./release.sh <version> "release notes"
```

---

## ⚠️ Notes

- Run as root only on trusted VPS instances.
- Keep an existing SSH session open before changing firewall, SSH, reinstall, or forwarding settings.
- Public scripts do not include private keys, private passwords, or personal-only initialization logic.
