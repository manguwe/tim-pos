# TIM-POS on Oracle Cloud Always Free (replaces Part C of RUNBOOK.md)

Goal: the server runs day and night on a free Oracle machine, at an HTTPS address like `https://timpos.duckdns.org`. No domain purchase. If Oracle fails at any step, the **Plan B** at the end (a small paid VPS) uses the same steps from step 5 onward.

Do the steps in order. Do not build the APK until step 12 is done: the APK has the server address inside it.

You will make these things. Write each into a notebook or password manager as you go:
Oracle account email and password, the SSH key file, the machine's public IP, the DuckDNS name and token, the vendor password.

---

## 1. Create the Oracle account

1. Go to **oracle.com/cloud/free** and click Start for free.
2. Fill in name, email, country (Zimbabwe), and verify your email.
3. **Home region:** this cannot be changed later. Choose the closest region offered to you (for example South Africa, Johannesburg, if it is in the list). Always Free machines must be made in this region.
4. Add your virtual card. Oracle makes a small temporary hold to check it, then releases it. Make sure the card has a small balance and online payments are enabled.
5. Wait for the "your account is ready" email (it can take minutes, sometimes longer), then sign in at cloud.oracle.com.

**If that fails:** card rejected → fund the virtual card a little, make sure the billing name/address matches what you typed, or try a different virtual card provider. Still failing → go to Plan B.

## 2. Create the machine

1. Menu (three lines, top left) → **Compute → Instances → Create instance**.
2. Name: `timpos`.
3. **Image and shape → Edit.**
   - Image: **Canonical Ubuntu 24.04** (or 22.04 if 24.04 is not listed).
   - Shape: Change shape → Virtual machine → **AMD** → **VM.Standard.E2.1.Micro**. It is labelled "Always Free-eligible". (1 GB memory is enough for us.) If you prefer the Arm shape (Ampere **VM.Standard.A1.Flex**, up to 2 OCPU and 12 GB) you can use it, but it often says out of capacity.
4. **Networking:** keep the default new network. Make sure **Assign a public IPv4 address** is on.
5. **Add SSH keys:** choose **Generate a key pair for me** and click **Save private key** (and save the public key too). This downloads a file like `ssh-key-2026-11-07.key`. Put it in a folder you will remember, for example `C:\Users\YOU\oracle\`. **Never share this file.** Lose it and you lose access.
6. Boot volume: leave the default (about 50 GB).
7. Click **Create**. Wait until the status turns green **Running**. Copy the **Public IP address** shown on the instance page.

**If you see "Out of host capacity":** try again in a few minutes, or at another time of day, or choose the other shape, or pick a different availability domain in the Placement box. Still failing after a few tries → Plan B.

## 3. Open the web ports in Oracle's network

1. On the instance page click the **Subnet** link under Primary VNIC, then the **Default Security List**.
2. **Add Ingress Rules**, two of them:
   - Source CIDR `0.0.0.0/0`, IP protocol TCP, Destination port `80`.
   - Source CIDR `0.0.0.0/0`, IP protocol TCP, Destination port `443`.
3. Do not open 8080 to the internet. Only Caddy talks to it.

## 4. Connect to the machine from your Windows PC

Open PowerShell and run (change the key path and IP):

```powershell
ssh -i "C:\Users\YOU\oracle\ssh-key-2026-11-07.key" ubuntu@YOUR_PUBLIC_IP
```

Type `yes` when it asks about the fingerprint. The prompt changes to `ubuntu@timpos:~$`. Everything in steps 5 to 11 is typed there.

**If it says "UNPROTECTED PRIVATE KEY FILE":** run these (change the path), then try again:

```powershell
icacls "C:\Users\YOU\oracle\ssh-key-2026-11-07.key" /inheritance:r
icacls "C:\Users\YOU\oracle\ssh-key-2026-11-07.key" /grant:r "$($env:USERNAME):(R)"
```

**If it times out:** the machine is not Running yet, the IP is wrong, or your network blocks port 22. Try again on mobile data. The username is always `ubuntu` on Ubuntu images.

## 5. Let the web traffic through the machine's own firewall

Oracle's Ubuntu image blocks ports even after step 3. On the machine run:

```bash
sudo iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
sudo apt update
sudo apt install -y iptables-persistent unzip curl
sudo netfilter-persistent save
```

If a pink screen asks to save current rules, answer Yes.

Add a little swap memory, because the free AMD machine has only 1 GB:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 6. Get your free name (DuckDNS)

1. Go to **duckdns.org** and sign in with Google or GitHub.
2. In "domains" type a name such as `timpos-tim` and click **add domain**. Your address is `timpos-tim.duckdns.org`. Pick something that is not obviously taken.
3. In the box "current ip" paste your Oracle **public IP** and click **update ip**.
4. Wait a minute. In PowerShell on your PC run `nslookup timpos-tim.duckdns.org`. It must show your Oracle IP.

The Oracle public IP stays the same while the machine exists (do not delete the machine). Keep your DuckDNS token private.

## 7. Install Node and Caddy

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node --version
```

It must print v22.18 or higher. If it prints something lower, run `sudo apt install -y nodejs` again or tell me the number.

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

## 8. Upload the project

On your **PC** (a second PowerShell window, not the ssh one), change the paths:

```powershell
scp -i "C:\Users\YOU\oracle\ssh-key-2026-11-07.key" C:\path\to\tim-pos-latest.zip ubuntu@YOUR_PUBLIC_IP:~/
```

Back in the ssh window:

```bash
sudo mkdir -p /opt && sudo unzip -q ~/tim-pos-latest.zip -d /opt
sudo chown -R ubuntu:ubuntu /opt/tim-pos
ls /opt/tim-pos          # you should see app dashboard server tools
```

(Use the real zip name. If the unzip makes `/opt/tim-pos/tim-pos`, move the inner folder up.)

Run the tests once on the machine:

```bash
cd /opt/tim-pos/server && npm test 2>&1 | tail -8
```

Expected: pass 99, fail 0.

## 9. Secrets (once, forever)

```bash
cd /opt/tim-pos/server
npm run -s cli -- gen-secrets > ~/secrets.env
chmod 600 ~/secrets.env
cat ~/secrets.env
```

**Copy everything it printed into your password manager or a file kept off this machine.** If you lose the private key you can never issue new licences. If it leaks, anyone can forge licences. Never regenerate it after shops are live.

## 10. Run the server as a service

```bash
sudo mkdir -p /var/lib/timpos && sudo chown ubuntu:ubuntu /var/lib/timpos
sudo tee /etc/systemd/system/timpos.service >/dev/null <<'EOF'
[Unit]
Description=TIM-POS server
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/opt/tim-pos/server
EnvironmentFile=/home/ubuntu/secrets.env
Environment=NODE_ENV=production
Environment=HOST=127.0.0.1
Environment=PORT=8080
Environment=TRUST_PROXY=1
Environment=DATA_DIR=/var/lib/timpos
ExecStart=/usr/bin/node --disable-warning=ExperimentalWarning src/server.ts
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now timpos
sudo systemctl status timpos --no-pager
curl -s http://127.0.0.1:8080/health
```

Status must say **active (running)** and curl must print an OK-style answer. If not: `sudo journalctl -u timpos -n 40 --no-pager` and send me the text. (If it complains about a missing or invalid key, send me the line. It would mean the key formatting in the secrets file needs a tweak.)

## 11. HTTPS with Caddy

Replace `timpos-tim` with your DuckDNS name:

```bash
sudo tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
timpos-tim.duckdns.org {
	encode gzip
	reverse_proxy 127.0.0.1:8080
}
EOF
sudo systemctl reload caddy
sudo systemctl status caddy --no-pager
```

Now on your PC open `https://timpos-tim.duckdns.org/dashboard/`. You should see the TIM-POS sign-in page with a padlock. The first load may take a few seconds while the certificate is issued.

**If it fails:**
- Browser cannot connect → step 3 (Oracle rule) or step 5 (machine firewall) was missed. Re-check both.
- Certificate error → the DuckDNS IP is wrong or not spread yet (`nslookup`), or ports 80 and 443 are closed. Look at `sudo journalctl -u caddy -n 40 --no-pager`.
- 502 Bad Gateway → the server is not running; go back to step 10.

Create your vendor login on this machine (it is a new database, separate from your PC):

```bash
cd /opt/tim-pos/server
set -a; . ~/secrets.env; set +a
NODE_ENV=production DATA_DIR=/var/lib/timpos npm run -s cli -- create-vendor --name "Tim" --email YOUR_EMAIL
```

Then sign in at the dashboard. Two-factor can wait (see the earlier advice); switch it on before real shops. Repeat Part B5 of RUNBOOK.md (plan, shop, licence key, billing details).

## 12. Print the key for the APK

```bash
cd /opt/tim-pos/server
set -a; . ~/secrets.env; set +a
NODE_ENV=production DATA_DIR=/var/lib/timpos npm run -s cli -- public-key --raw
```

Copy the one line. Now go to **RUNBOOK.md Part D, route 1** with:
- `TIMPOS_SERVER_URL` = `https://timpos-tim.duckdns.org` (your name, no slash, no /dashboard)
- `TIMPOS_LICENCE_PUBLIC_KEY` = the line you just copied

Use licence keys made on **this** Oracle server, never on your PC's test server.

## 13. Protect against reboot, idle reclamation, and mistakes

1. **Reboot test:** `sudo reboot`, wait two minutes, reconnect, then the dashboard must still open by itself.
2. **Daily backup** on the machine:

```bash
mkdir -p ~/backups
cat > ~/backup.sh <<'EOF'
#!/bin/bash
set -a; . /home/ubuntu/secrets.env; set +a
cd /opt/tim-pos/server
f=/home/ubuntu/backups/timpos-$(date +%F).db
rm -f "$f"
NODE_ENV=production DATA_DIR=/var/lib/timpos npm run -s cli -- backup "$f"
find /home/ubuntu/backups -name 'timpos-*.db' -mtime +14 -delete
EOF
chmod +x ~/backup.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /home/ubuntu/backup.sh") | crontab -
~/backup.sh && ls -la ~/backups
```

3. **Copy a backup off the machine** regularly. On your PC: `scp -i "KEY" ubuntu@IP:~/backups/timpos-*.db C:\backups\`. A backup on the same machine is lost if Oracle deletes the machine.
4. **Idle reclamation:** Oracle may stop and remove Always Free machines it considers idle for 7 days (low CPU, network and, on Arm, memory). Our server is light, so this could happen. Ways to reduce the risk: upgrade the account to **Pay As You Go** in the Oracle console (you stay free while inside the free limits, but please read their current wording and watch the Billing page), and keep your off-machine backups. If the machine is ever deleted, create a new one, repeat steps 2 to 11, restore the newest backup into `/var/lib/timpos/tim-pos.db`, and run the `new-sync-epoch` command. Keep the **same** secrets, so phones keep working.
5. **Updates:** about once a month: `sudo apt update && sudo apt upgrade -y` then `sudo reboot`.

## Plan B: a paid VPS (about USD 4 to 6 a month)

Any Ubuntu 24.04 VPS (Hetzner, DigitalOcean, Contabo, Vultr). Skip steps 1 to 4. Create the VPS, note its IP and login, SSH in, then do steps 5 (swap and the `ufw allow 22,80,443` firewall instead of iptables), 6, 7, 8, 9, 10, 11, 12, 13. The username may be `root` instead of `ubuntu`; if so, change `User=ubuntu` and the `/home/ubuntu` paths accordingly, or create an `ubuntu` user first.

## Quick problem table

| Symptom | Fix |
|---|---|
| `ssh` timeout | Machine not Running, wrong IP, or try another network |
| Site does not load | Steps 3 and 5 (both firewalls), then DuckDNS IP |
| Padlock error | DuckDNS IP wrong, or port 80 blocked so Caddy cannot get the certificate |
| 502 | `sudo systemctl status timpos`, `journalctl -u timpos -n 40` |
| Forgot the sign-in password | Create a new vendor with a different email using step 11's command, then tell me if you want the old one removed |
| Everything gone after Oracle deleted the machine | Step 13 recovery. This is why backups leave the machine |
