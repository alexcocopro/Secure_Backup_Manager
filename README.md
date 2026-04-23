# Secure Backup Manager

**ES:** Gestor seguro de respaldos para Linux con programacion persistente, respaldos completos e incrementales, cifrado opcional con contrasena, verificacion SHA256, restauracion, envio remoto por SSH, logs y notificaciones por email.

**EN:** Secure Linux backup manager with persistent scheduling, full and incremental backups, optional password-based encryption, SHA256 verification, restore workflow, SSH remote transfer, logs, and email notifications.

**Elaborado por / Created by:** Alex Jesus Cabello Leiva  
**Cargo / Role:** Lider de proyectos de innovacion y consultor en ciberseguridad / Innovation project leader and cybersecurity consultant

---

## ES - Caracteristicas

- Interfaz interactiva en espanol e ingles.
- Respaldos completos e incrementales.
- Programacion diaria, semanal o mensual con `systemd timers`.
- Persistencia tras reinicio con `Persistent=true`.
- Respaldo de directorios.
- Respaldo de PostgreSQL con `pg_dumpall` o `pg_dump`.
- Respaldo de MySQL/MariaDB con `mysqldump`.
- Modo logico en caliente o modo frio deteniendo servicios.
- Cifrado opcional del archivo de respaldo con OpenSSL `AES-256-CBC` y PBKDF2.
- Descifrado durante restauracion mediante contrasena.
- Hash SHA256 para verificar integridad del archivo guardado, cifrado o no cifrado.
- Estado de respaldos: `VERIFICADO` o `NO VERIFICADO`.
- Restauracion de cadena full + incrementales.
- Envio remoto con `rsync` sobre SSH usando llaves.
- Logs en `/var/log/secure-backup-manager`.
- Notificaciones por email con `mail`, `mailx` o `sendmail`.
- Eliminacion de trabajos con limpieza de timers.

## EN - Features

- Interactive interface in Spanish and English.
- Full and incremental backups.
- Daily, weekly, or monthly scheduling with `systemd timers`.
- Reboot persistence with `Persistent=true`.
- Directory backups.
- PostgreSQL backups with `pg_dumpall` or `pg_dump`.
- MySQL/MariaDB backups with `mysqldump`.
- Logical hot backup mode or cold mode by stopping services.
- Optional backup archive encryption with OpenSSL `AES-256-CBC` and PBKDF2.
- Password-based decryption during restore.
- SHA256 hash verification for the stored file, encrypted or unencrypted.
- Backup state: `VERIFIED` or `NOT VERIFIED`.
- Full + incremental chain restore.
- Remote transfer with `rsync` over SSH keys.
- Logs in `/var/log/secure-backup-manager`.
- Email notifications with `mail`, `mailx`, or `sendmail`.
- Job deletion with timer cleanup.

---

## ES - Requisitos

Sistema Linux con:

- Bash
- systemd
- tar
- gzip
- coreutils
- rsync
- OpenSSH client
- OpenSSL
- util-linux, para `flock`
- PostgreSQL tools, si respaldara PostgreSQL
- MySQL/MariaDB client tools, si respaldara MySQL/MariaDB
- mailutils, mailx o sendmail, si usara email

El instalador intenta instalar dependencias basicas usando `apt`, `dnf`, `yum`, `zypper` o `pacman`.

## EN - Requirements

Linux system with:

- Bash
- systemd
- tar
- gzip
- coreutils
- rsync
- OpenSSH client
- OpenSSL
- util-linux, for `flock`
- PostgreSQL tools, if PostgreSQL will be backed up
- MySQL/MariaDB client tools, if MySQL/MariaDB will be backed up
- mailutils, mailx, or sendmail, if email notifications are used

The installer tries to install basic dependencies using `apt`, `dnf`, `yum`, `zypper`, or `pacman`.

---

## ES - Instalacion

```bash
chmod +x secure_backup_manager.sh
sudo ./secure_backup_manager.sh install
```

Esto instala el comando global:

```bash
/usr/local/sbin/secure-backup-manager
```

Ejecutar menu:

```bash
sudo secure-backup-manager
```

## EN - Installation

```bash
chmod +x secure_backup_manager.sh
sudo ./secure_backup_manager.sh install
```

This installs the global command:

```bash
/usr/local/sbin/secure-backup-manager
```

Run menu:

```bash
sudo secure-backup-manager
```

---

## ES - Crear un trabajo de respaldo

```bash
sudo secure-backup-manager configure
```

El asistente preguntara:

- Idioma.
- Nombre del trabajo.
- Ruta local donde se guardaran respaldos.
- Retencion local en dias.
- Directorios a respaldar.
- Exclusiones opcionales.
- Si desea respaldar base de datos.
- Tipo de base de datos.
- Modo logico o frio.
- Servicios a detener, si aplica.
- Frecuencia, dia y hora del respaldo incremental.
- Frecuencia, dia y hora del respaldo completo.
- Destino remoto por SSH, si aplica.
- Email de notificaciones, si aplica.
- Si desea cifrar los respaldos con contrasena.

Importante: si activa cifrado, la contrasena se guarda en un archivo protegido por root para que los respaldos programados puedan ejecutarse sin intervencion. Debe conservar una copia segura de esa contrasena para poder restaurar.

## EN - Create a backup job

```bash
sudo secure-backup-manager configure
```

The wizard asks for:

- Language.
- Job name.
- Local backup path.
- Local retention in days.
- Directories to back up.
- Optional exclusions.
- Whether to back up databases.
- Database type.
- Logical or cold mode.
- Services to stop, if needed.
- Incremental backup frequency, day, and time.
- Full backup frequency, day, and time.
- SSH remote destination, if needed.
- Notification email, if needed.
- Whether backups should be password-encrypted.

Important: if encryption is enabled, the password is stored in a root-protected file so scheduled backups can run without interaction. You must keep a secure copy of that password to restore.

---

## ES - Cifrado de respaldos

Al activar cifrado, el programa:

1. Crea el archivo temporal `.tar.gz`.
2. Lo cifra con OpenSSL `AES-256-CBC`, `PBKDF2` e iteraciones altas.
3. Guarda el archivo final como:

```text
JOB_ID-BACKUP_ID.tar.gz.enc
```

4. Elimina el `.tar.gz` sin cifrar.
5. Calcula SHA256 sobre el archivo cifrado.
6. Envia el archivo cifrado al remoto, si esta configurado.

Durante la configuracion del trabajo cifrado se pedira:

```text
Password de cifrado / Encryption password
Confirmar password / Confirm password
```

La contrasena se guarda en:

```bash
/etc/secure-backup-manager/.secrets/JOB_ID.encpass
```

con permisos `600` y acceso root. El directorio `.secrets` tiene permisos `700`.

El programa no coloca la contrasena en variables de entorno ni en argumentos visibles de proceso. Para OpenSSL usa `-pass file:...`, evitando exponer el secreto en `ps`, `top` o logs.

## EN - Backup encryption

When encryption is enabled, the program:

1. Creates a temporary `.tar.gz` file.
2. Encrypts it with OpenSSL `AES-256-CBC`, `PBKDF2`, and high iterations.
3. Stores the final file as:

```text
JOB_ID-BACKUP_ID.tar.gz.enc
```

4. Deletes the unencrypted `.tar.gz`.
5. Computes SHA256 over the encrypted file.
6. Sends the encrypted file to the remote host, if configured.

During encrypted job configuration, the program asks for:

```text
Password de cifrado / Encryption password
Confirmar password / Confirm password
```

The password is stored in:

```bash
/etc/secure-backup-manager/.secrets/JOB_ID.encpass
```

with `600` permissions and root access. The `.secrets` directory has `700` permissions.

The program does not put the password in environment variables or process-visible arguments. It uses OpenSSL `-pass file:...`, avoiding secret exposure in `ps`, `top`, or logs.

---

## ES - Ejecutar respaldos manuales

Desde el menu interactivo, las opciones de respaldo completo e incremental permiten:

- Seleccionar un trabajo existente desde una lista.
- Crear/configurar un trabajo nuevo y ejecutarlo inmediatamente.

Por consola tambien puede ejecutarse indicando el `JOB_ID`.

Completo:

```bash
sudo secure-backup-manager run JOB_ID full
```

Incremental:

```bash
sudo secure-backup-manager run JOB_ID incremental
```

Ejemplo:

```bash
sudo secure-backup-manager run etc full
sudo secure-backup-manager run etc incremental
```

## EN - Run manual backups

From the interactive menu, the full and incremental backup options let you:

- Select an existing job from a list.
- Create/configure a new job and run it immediately.

From the command line, you can still run a backup by passing the `JOB_ID`.

Full:

```bash
sudo secure-backup-manager run JOB_ID full
```

Incremental:

```bash
sudo secure-backup-manager run JOB_ID incremental
```

Example:

```bash
sudo secure-backup-manager run etc full
sudo secure-backup-manager run etc incremental
```

---

## ES - Consultar trabajos y configuracion

Ver todos los trabajos:

```bash
sudo secure-backup-manager status
```

Ver un trabajo y su configuracion completa:

```bash
sudo secure-backup-manager status JOB_ID
```

La salida incluye rutas, retencion, base de datos, modo, calendarios, configuracion remota, SSH, email, cifrado, directorios, exclusiones, servicios y resumen de verificacion.

## EN - Check jobs and configuration

Show all jobs:

```bash
sudo secure-backup-manager status
```

Show one job and its full configuration:

```bash
sudo secure-backup-manager status JOB_ID
```

The output includes paths, retention, database, mode, schedules, remote setup, SSH, email, encryption, directories, exclusions, services, and verification summary.

---

## ES - Listar y verificar respaldos

```bash
sudo secure-backup-manager list
sudo secure-backup-manager list JOB_ID
sudo secure-backup-manager verify JOB_ID BACKUP_ID
```

`list` sin `JOB_ID` muestra todos los respaldos configurados con sus calendarios, directorios, email, cifrado, remoto, retencion y respaldos realizados. En el menu interactivo, el programa pausa despues de mostrar el listado para que pueda revisarse antes de volver al menu.

Ejemplo:

```text
20260420-223057-full         VERIFICADO
20260421-020001-incremental  NO VERIFICADO
```

`verify` comprueba el SHA256 del archivo guardado. Si el respaldo esta cifrado, verifica el `.enc`.

## EN - List and verify backups

```bash
sudo secure-backup-manager list
sudo secure-backup-manager list JOB_ID
sudo secure-backup-manager verify JOB_ID BACKUP_ID
```

`list` without `JOB_ID` shows all configured backup jobs with schedules, directories, email, encryption, remote settings, retention, and completed backups. In the interactive menu, the program pauses after showing the list so it can be reviewed before returning to the menu.

Example:

```text
20260420-223057-full         VERIFIED
20260421-020001-incremental  NOT VERIFIED
```

`verify` checks the SHA256 of the stored file. If the backup is encrypted, it verifies the `.enc` file.

---

## ES - Restaurar respaldos

```bash
sudo secure-backup-manager restore JOB_ID BACKUP_ID /ruta/destino
```

Ejemplo:

```bash
sudo secure-backup-manager restore etc 20260420-223057-full /tmp/restore-etc
```

Si el respaldo esta cifrado, el programa pedira:

```text
Password de descifrado / Decryption password
```

Luego descifra a un archivo temporal, extrae el contenido y elimina el temporal.

Si el respaldo seleccionado es incremental, restaura la cadena correspondiente: full base y los incrementales necesarios.

## EN - Restore backups

```bash
sudo secure-backup-manager restore JOB_ID BACKUP_ID /restore/path
```

Example:

```bash
sudo secure-backup-manager restore etc 20260420-223057-full /tmp/restore-etc
```

If the backup is encrypted, the program asks for:

```text
Password de descifrado / Decryption password
```

Then it decrypts to a temporary file, extracts the content, and removes the temporary file.

If the selected backup is incremental, it restores the required chain: base full plus needed incrementals.

---

## ES - Desencriptar un respaldo cifrado

Para descifrar un `.tar.gz.enc` sin restaurarlo:

```bash
sudo secure-backup-manager decrypt JOB_ID BACKUP_ID /ruta/salida.tar.gz
```

Tambien puede usar la opcion del menu `Desencriptar respaldo cifrado`. El programa muestra solo respaldos cifrados, verifica el SHA256 del `.enc`, pide la contrasena y genera un `.tar.gz` descifrado en la ruta indicada.

Advertencia: el `.tar.gz` descifrado contiene los datos originales sin cifrar. Protejalo con permisos adecuados y eliminelo cuando ya no sea necesario.

## EN - Decrypt an encrypted backup

To decrypt a `.tar.gz.enc` without restoring it:

```bash
sudo secure-backup-manager decrypt JOB_ID BACKUP_ID /path/output.tar.gz
```

You can also use the `Decrypt encrypted backup` menu option. The program shows only encrypted backups, verifies the `.enc` SHA256, asks for the password, and creates a decrypted `.tar.gz` at the selected path.

Warning: the decrypted `.tar.gz` contains the original data without encryption. Protect it with appropriate permissions and remove it when it is no longer needed.

---

## ES - Respaldo remoto por SSH

Mostrar o generar llave publica:

```bash
sudo secure-backup-manager remote-key JOB_ID
```

La llave publica debe instalarse en el equipo remoto en:

```bash
/home/USUARIO_REMOTO/.ssh/authorized_keys
```

Para `backup`:

```bash
/home/backup/.ssh/authorized_keys
```

Para `root`:

```bash
/root/.ssh/authorized_keys
```

Instalacion manual en el remoto:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Pegue la linea completa `ssh-ed25519 ...` que entrega el programa.

Con usuario `backup`, ejecutado como root:

```bash
sudo mkdir -p /home/backup/.ssh
sudo nano /home/backup/.ssh/authorized_keys
sudo chown -R backup:backup /home/backup/.ssh
sudo chmod 700 /home/backup/.ssh
sudo chmod 600 /home/backup/.ssh/authorized_keys
```

Con `ssh-copy-id`:

```bash
sudo ssh-copy-id -i /etc/secure-backup-manager/ssh/JOB_ID_ed25519.pub USUARIO@HOST
```

Con puerto alterno:

```bash
sudo ssh-copy-id -p 2222 -i /etc/secure-backup-manager/ssh/JOB_ID_ed25519.pub USUARIO@HOST
```

Probar conexion:

```bash
sudo ssh -i /etc/secure-backup-manager/ssh/JOB_ID_ed25519 USUARIO@HOST
```

La ruta remota debe tener formato:

```text
usuario@host:/ruta/remota
```

## EN - SSH remote backup

Show or generate public key:

```bash
sudo secure-backup-manager remote-key JOB_ID
```

The public key must be installed on the remote host in:

```bash
/home/REMOTE_USER/.ssh/authorized_keys
```

For `backup`:

```bash
/home/backup/.ssh/authorized_keys
```

For `root`:

```bash
/root/.ssh/authorized_keys
```

Manual installation on the remote host:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Paste the full `ssh-ed25519 ...` line printed by the program.

For user `backup`, executed as root:

```bash
sudo mkdir -p /home/backup/.ssh
sudo nano /home/backup/.ssh/authorized_keys
sudo chown -R backup:backup /home/backup/.ssh
sudo chmod 700 /home/backup/.ssh
sudo chmod 600 /home/backup/.ssh/authorized_keys
```

With `ssh-copy-id`:

```bash
sudo ssh-copy-id -i /etc/secure-backup-manager/ssh/JOB_ID_ed25519.pub USER@HOST
```

With alternate port:

```bash
sudo ssh-copy-id -p 2222 -i /etc/secure-backup-manager/ssh/JOB_ID_ed25519.pub USER@HOST
```

Test connection:

```bash
sudo ssh -i /etc/secure-backup-manager/ssh/JOB_ID_ed25519 USER@HOST
```

Remote path format:

```text
user@host:/remote/path
```

---

## ES - Programacion con systemd

Cada trabajo crea:

```text
secure-backup-manager-JOB_ID-full.timer
secure-backup-manager-JOB_ID-incremental.timer
```

Ver timers:

```bash
systemctl list-timers 'secure-backup-manager-*'
```

Ver estado:

```bash
systemctl status secure-backup-manager-JOB_ID-full.timer
systemctl status secure-backup-manager-JOB_ID-incremental.timer
```

## EN - systemd scheduling

Each job creates:

```text
secure-backup-manager-JOB_ID-full.timer
secure-backup-manager-JOB_ID-incremental.timer
```

Show timers:

```bash
systemctl list-timers 'secure-backup-manager-*'
```

Show status:

```bash
systemctl status secure-backup-manager-JOB_ID-full.timer
systemctl status secure-backup-manager-JOB_ID-incremental.timer
```

---

## ES - Logs

```bash
/var/log/secure-backup-manager
```

Ejemplo:

```bash
sudo tail -100 /var/log/secure-backup-manager/JOB_ID-*.log
```

## EN - Logs

```bash
/var/log/secure-backup-manager
```

Example:

```bash
sudo tail -100 /var/log/secure-backup-manager/JOB_ID-*.log
```

---

## ES - Eliminar trabajos y respaldos

```bash
sudo secure-backup-manager delete
sudo secure-backup-manager delete JOB_ID
```

`delete` sin argumentos abre un menu con estas opciones:

- Eliminar todos los trabajos sin eliminar respaldos.
- Eliminar todos los respaldos sin eliminar trabajos.
- Seleccionar un trabajo para eliminarlo sin eliminar sus respaldos.
- Seleccionar un respaldo realizado para eliminarlo individualmente.

`delete JOB_ID` mantiene el flujo clasico: muestra la configuracion, deshabilita timers, elimina archivos de systemd y pregunta si desea eliminar respaldos locales, llave SSH y password de cifrado guardado.

Cuando se eliminan respaldos pero se conservan trabajos, el programa reinicia el estado incremental para que el proximo incremental cree un nuevo full si hace falta.

## EN - Delete jobs and backups

```bash
sudo secure-backup-manager delete
sudo secure-backup-manager delete JOB_ID
```

`delete` without arguments opens a menu with these options:

- Delete all jobs without deleting backups.
- Delete all backups without deleting jobs.
- Select one job and delete it without deleting its backups.
- Select one completed backup and delete it individually.

`delete JOB_ID` keeps the classic flow: it shows the configuration, disables timers, removes systemd files, and asks whether local backups, the SSH key, and the stored encryption password should be deleted.

When backups are deleted but jobs are kept, the program resets incremental state so the next incremental can create a new full if needed.

---

## ES - Estructura de archivos

```bash
/etc/secure-backup-manager          # configuracion
/etc/secure-backup-manager/jobs     # trabajos
/etc/secure-backup-manager/state    # estado incremental
/etc/secure-backup-manager/ssh      # llaves SSH
/etc/secure-backup-manager/.secrets # contrasenas de cifrado protegidas por root
/var/backups/secure-backup-manager  # respaldos locales
/var/log/secure-backup-manager      # logs
```

## EN - File structure

```bash
/etc/secure-backup-manager          # configuration
/etc/secure-backup-manager/jobs     # jobs
/etc/secure-backup-manager/state    # incremental state
/etc/secure-backup-manager/ssh      # SSH keys
/etc/secure-backup-manager/.secrets # root-protected encryption passwords
/var/backups/secure-backup-manager  # local backups
/var/log/secure-backup-manager      # logs
```

---

## ES - Seguridad

- Use un usuario remoto dedicado, por ejemplo `backup`.
- No use contrasenas SSH para automatizacion; use llaves.
- Proteja `/etc/secure-backup-manager/ssh`.
- Instale la llave publica en el remoto con privilegios minimos: usuario dedicado, ruta limitada y sin acceso administrativo.
- Si usa cifrado, guarde una copia de la contrasena en un gestor seguro.
- Proteja `/etc/secure-backup-manager/.secrets`.
- No copie los archivos de secretos a destinos remotos ni repositorios.
- No ejecute el programa con `set -x` porque podria imprimir rutas y flujo sensible.
- Sin la contrasena no se podra restaurar un respaldo cifrado.
- Verifique periodicamente con `verify`.
- Pruebe restauraciones en una ruta temporal.
- Evite respaldar `/proc`, `/sys`, `/dev` y `/run`.

Modelo de secretos:

- Los secretos se guardan bajo `/etc/secure-backup-manager/.secrets`.
- El directorio usa permisos `700`.
- Los archivos de contrasena usan permisos `600`.
- El script fija `umask 077`.
- Las contrasenas no se pasan a OpenSSL como argumentos visibles.
- OpenSSL recibe la contrasena con `-pass file:...`.
- No se usan variables de entorno para contrasenas.
- Si un atacante obtiene root, puede leer secretos y usar llaves SSH privadas; use cifrado de disco, hardening del servidor y restricciones en `authorized_keys` como `from=`, `command=`, `no-agent-forwarding`, `no-X11-forwarding` y `no-pty` para reducir riesgo de movimiento lateral.

## EN - Security

- Use a dedicated remote user, for example `backup`.
- Do not use SSH passwords for automation; use keys.
- Protect `/etc/secure-backup-manager/ssh`.
- Install the public key on the remote host with minimum privileges: dedicated user, limited path, and no administrative access.
- If encryption is enabled, store a copy of the password in a secure password manager.
- Protect `/etc/secure-backup-manager/.secrets`.
- Do not copy secret files to remote destinations or repositories.
- Do not run the program with `set -x` because it may print sensitive execution flow and paths.
- Without the password, encrypted backups cannot be restored.
- Verify periodically with `verify`.
- Test restores in a temporary path.
- Avoid backing up `/proc`, `/sys`, `/dev`, and `/run`.

Secrets model:

- Secrets are stored under `/etc/secure-backup-manager/.secrets`.
- The directory uses `700` permissions.
- Password files use `600` permissions.
- The script sets `umask 077`.
- Passwords are not passed to OpenSSL as process-visible arguments.
- OpenSSL receives passwords with `-pass file:...`.
- Password environment variables are not used.
- If an attacker gets root, secrets can be read and private SSH keys can be used; use disk encryption, host hardening, and `authorized_keys` restrictions such as `from=`, `command=`, `no-agent-forwarding`, `no-X11-forwarding`, and `no-pty` to reduce lateral movement risk.

---

## ES - Comandos rapidos

```bash
sudo ./secure_backup_manager.sh install
sudo secure-backup-manager configure
sudo secure-backup-manager status
sudo secure-backup-manager status JOB_ID
sudo secure-backup-manager run JOB_ID full
sudo secure-backup-manager run JOB_ID incremental
sudo secure-backup-manager list JOB_ID
sudo secure-backup-manager verify JOB_ID BACKUP_ID
sudo secure-backup-manager restore JOB_ID BACKUP_ID /ruta/destino
sudo secure-backup-manager decrypt JOB_ID BACKUP_ID /ruta/salida.tar.gz
sudo secure-backup-manager remote-key JOB_ID
sudo secure-backup-manager delete
sudo secure-backup-manager delete JOB_ID
```

## EN - Quick commands

```bash
sudo ./secure_backup_manager.sh install
sudo secure-backup-manager configure
sudo secure-backup-manager status
sudo secure-backup-manager status JOB_ID
sudo secure-backup-manager run JOB_ID full
sudo secure-backup-manager run JOB_ID incremental
sudo secure-backup-manager list JOB_ID
sudo secure-backup-manager verify JOB_ID BACKUP_ID
sudo secure-backup-manager restore JOB_ID BACKUP_ID /restore/path
sudo secure-backup-manager decrypt JOB_ID BACKUP_ID /path/output.tar.gz
sudo secure-backup-manager remote-key JOB_ID
sudo secure-backup-manager delete
sudo secure-backup-manager delete JOB_ID
```
