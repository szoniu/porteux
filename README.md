# PorteuX TUI Installer

Interaktywny instalator TUI (Terminal User Interface) dla [PorteuX](https://github.com/porteux/porteux) — lekkiej, modularnej dystrybucji Linuksa opartej na Slackware.

## Czym jest PorteuX?

PorteuX to szybka, modularna i przenośna dystrybucja oparta na Slackware current (rolling). System składa się z modułów squashfs (.xzm) nakładanych warstwami przez AUFS:

- **Superszybki** — LXQt bootuje w ~3 sekundy
- **Modularny** — system = zestaw modułów .xzm, aktywowanych/deaktywowanych w locie
- **Przenośny** — uruchom z USB, SSD, a nawet z RAM (Copy to RAM)
- **Opcjonalnie niezmienny** — tryb "Always Fresh" resetuje system przy każdym restarcie
- **8 wariantów desktopowych** — KDE, Xfce, LXQt, Cinnamon, MATE, GNOME, LXDE, COSMIC

## Wymagania

- **Komputer** z procesorem x86-64 (SSE4.2)
- **Pamięć RAM**: 2+ GB (4+ GB dla Copy to RAM)
- **Dysk**: 4+ GB wolnego miejsca
- **Internet** (do pobrania ISO)
- **Bootowalny pendrive** z dowolnym Linux Live ISO (do uruchomienia instalatora)
- **UEFI** lub **BIOS** (oba obsługiwane)

## Szybki start

```bash
# 1. Uruchom dowolne Live ISO z dostępem do internetu
# 2. Sklonuj repozytorium
git clone https://github.com/szoniu/porteux.git
cd porteux

# 3. Uruchom instalator jako root
sudo ./install.sh
```

## Tryby uruchomienia

```bash
./install.sh              # Pełna instalacja (wizard + instalacja)
./install.sh --configure  # Tylko konfiguracja (generuje plik .conf)
./install.sh --install    # Tylko instalacja (z istniejącym .conf)
./install.sh --resume     # Wznów przerwaną instalację
./install.sh --dry-run    # Symulacja (bez destrukcyjnych operacji)
```

### Opcje

| Opcja | Opis |
|---|---|
| `--config FILE` | Użyj podanego pliku konfiguracji |
| `--dry-run` | Symulacja bez destrukcyjnych operacji |
| `--force` | Kontynuuj mimo nieudanych sprawdzeń |
| `--non-interactive` | Przerwij przy błędzie (bez menu naprawczego) |

## Ekrany TUI (17 kroków)

1. **Witaj** — sprawdzenie wymagań (root, sieć, EFI/BIOS)
2. **Preset** — załaduj zapisaną konfigurację lub zacznij od nowa
3. **Sprzęt** — automatyczna detekcja CPU, GPU, dysków, peryferiów
4. **Dysk** — wybór dysku docelowego, schemat partycji (auto/dual-boot/manual)
5. **System plików** — ext4, FAT32, btrfs, XFS
6. **Swap** — brak, partycja, plik
7. **Desktop** — 8 wariantów: KDE, Xfce, LXQt, Cinnamon, MATE, GNOME, LXDE, COSMIC
8. **GPU** — konfiguracja sterowników, opcjonalny moduł NVIDIA
9. **Serwer graficzny** — auto / Wayland / X11 (COSMIC tylko Wayland; XFCE/MATE/Cinnamon/LXDE tylko X11)
10. **Persystencja** — persistent (zmiany zachowane) / immutable (zawsze świeży)
11. **Tryb boot** — normalny, Copy to RAM, Always Fresh, tekst
12. **Moduły** — opcjonalne moduły: devel, multilanguage, multilib
13. **Sieć** — hostname
14. **Lokalizacja** — strefa czasowa, locale, keymap
15. **Użytkownicy** — hasło root, konto użytkownika
16. **Preset** — opcjonalny zapis konfiguracji
17. **Podsumowanie** — przegląd + potwierdzenie YES + odliczanie

## Fazy instalacji

| # | Faza | Opis |
|---|---|---|
| 1 | Preflight | Sprawdzenie wymagań systemowych |
| 2 | Dyski | Partycjonowanie (sfdisk), formatowanie, montowanie |
| 3 | ISO download | Pobranie PorteuX ISO dla wybranego desktopu |
| 4 | ISO verify | Weryfikacja SHA256 (jeśli dostępna) |
| 5 | ISO extract | Ekstrakcja zawartości ISO na partycję |
| 6 | Bootloader | syslinux (EFI i BIOS — z ISO PorteuX, bez GRUB-a) |
| 7 | Persystencja | Konfiguracja katalogu zmian AUFS |
| 8 | Moduły | Pobranie opcjonalnych modułów .xzm |
| 9 | System | Hostname, timezone, locale, keymap |
| 10 | Użytkownicy | Skrypt first-boot z konfiguracją kont |
| 11 | Finalizacja | Weryfikacja modułów, sync, cleanup |

## Detekcja sprzętu

Instalator automatycznie wykrywa:
- **CPU** — producent, model, liczba rdzeni
- **GPU** — NVIDIA/AMD/Intel, hybrid GPU (iGPU+dGPU), zalecany sterownik
- **Dyski** — SATA, NVMe, USB, rozmiar, model
- **Peryferia** — Bluetooth, czytnik linii papilarnych, Thunderbolt, sensory IIO, kamera, WWAN
- **Zainstalowane OS** — Windows, Linux (wykrywanie ESP + partycji)
- **ASUS ROG** — laptopy ROG/TUF
- **Microsoft Surface** — detekcja modelu via DMI

## Dual-boot

Instalator wspiera dual-boot z Windows i innymi systemami Linux:
- Automatyczna detekcja zainstalowanych systemów
- Współdzielenie istniejącego ESP (nigdy nie formatuje)
- Wizard kurczenia partycji (NTFS, ext4, btrfs)
- Nowa partycja root tworzona w wolnym miejscu i wykrywana po `sfdisk --append` (nigdy nie zgaduje numeru → nie sformatuje cudzej partycji)
- Osobny wpis bootowania UEFI dla PorteuX (PorteuX używa syslinux, nie GRUB-a) — system wybierasz z menu boot firmware

## Persystencja w PorteuX

PorteuX używa AUFS (Another Union File System) do nakładania warstw:

| Tryb | Parametr boot | Opis |
|---|---|---|
| **Persistent** | `changes=/porteux` | Zmiany zapisywane na bieżąco na dysk (PorteuX tworzy podkatalog `changes/` w `/porteux`) — to wpisuje instalator |
| **Persistent (live)** | `changes=EXIT:/porteux` | Upstreamowy tryb dla USB: zmiany w RAM, zrzut na dysk dopiero przy czystym zamknięciu |
| **Immutable** | `baseonly norootcopy` | Świeży system po każdym restarcie (etykiety `fresh` / `text-fresh`) |
| **Copy to RAM** | `copy2ram` | Cała baza kopiowana do RAM. **To NIE jest tryb persystencji** — trzeba go łączyć z `changes=`, inaczej sesja wstaje bez Twojej warstwy |

> **Warstwa `changes` to cała Twoja konfiguracja.** Konta i hasła (skrypt first-boot), hostname, locale, `sudoers`/polkit dla `wheel`, autologin i helper `porteux-update-modules` leżą w `/porteux/changes`. Etykieta bootowa **bez** `changes=` startuje system, w którym nic z tego nie istnieje — root wraca do fabrycznego `toor`, a helper „nie istnieje". Instalator wpisuje dlatego `changes=` do **każdej** etykiety poza `fresh`/`text-fresh`. Instalacja zrobiona wcześniejszą wersją instalatora ma go tylko na etykiecie domyślnej — naprawia to `porteux-update-modules --fix-persistence`.

## Moduły opcjonalne

| Moduł | Opis |
|---|---|
| `05-devel` | Narzędzia developerskie (GCC, make, git, cmake) |
| `08-multilanguage` | Wsparcie wielu języków (dane locale) |
| `0050-multilib-lite` | Biblioteki 32-bitowe (kompatybilność) |
| `nvidia-driver` | Sterowniki NVIDIA (własnościowe) |

Moduły **wybrane w kreatorze** instalator kładzie do `/porteux/modules/`, skąd ładują się **automatycznie przy każdym starcie** — nic nie trzeba aktywować. Katalog `/porteux/optional/` to miejsce na moduły „odstawione": nie ładują się same, uruchamia je `activate <moduł>` albo cheatcode `load=`.

Trzy katalogi modułów na nośniku (nie mylić ich):

| Katalog | Co tam jest | Kiedy się ładuje |
|---|---|---|
| `/porteux/base/` | `000-kernel`, `001-core`, `002-gui`, `002-xtra`, `003-<pulpit>` — sam system z ISO | automatycznie; podmienia je tylko upgrade z nowego ISO |
| `/porteux/modules/` | moduły dodatkowe (Twoje + te z kreatora) | automatycznie przy każdym starcie |
| `/porteux/optional/` | moduły odstawione | tylko ręcznie (`activate`, `load=`) |

> **Locale spoza angielskiego:** baza PorteuX zawiera tylko locale `C`/`en_US`. Jeśli na ekranie lokalizacji wybierzesz np. `pl_PL.UTF-8`, instalator **automatycznie** pobierze moduł `08-multilanguage` (glibc-i18n) i umieści go w `/porteux/modules/`, żeby język działał już po pierwszym starcie — bez ręcznej aktywacji.

## Po instalacji

PorteuX nie ma menedżera pakietów w klasycznym sensie — dodatkowe oprogramowanie instaluje się przez **PorteuX App Store** (`porteux-app-store`, dostępny w menu pulpitu) albo ręcznie modułami `.xzm`.

- **Moduły z kreatora działają od razu** — leżą w `/porteux/modules/` i ładują się przy każdym starcie. Ręcznej aktywacji (`activate /porteux/optional/<moduł>.xzm`) wymagają tylko moduły, które sam wrzucisz do `/porteux/optional/`.
- **Dane logowania:** do momentu pierwszego uruchomienia (które stosuje Twoje ustawienia) obowiązują domyślne: `root`/`toor`, `guest`/`guest`. Skrypt first-boot ustawia Twoje hasła/użytkownika przy pierwszym starcie.
- **UMPC:** ewentualne uwagi poinstalacyjne zapisywane są do `/root/POST-INSTALL-NOTES.txt`.

## Aktualizacja systemu

PorteuX nie ma `apt`/`dnf`/`slackpkg` jako głównego mechanizmu — system to **moduły squashfs** (`.xzm`). Są **dwie** ścieżki aktualizacji, bo release publikuje jako osobne pliki tylko część modułów:

- **Moduły opcjonalne** (`05-devel`, `08-multilanguage`, `0050-multilib-lite`) — publikowane jako **datowane assety** (np. `08-multilanguage-current-**20260823**.xzm`). Podmiana po nowszym datowniku: tryb `--download`.
- **Baza** (`000-kernel`/`001-core`/`002-gui`/`002-xtra`/`003-<pulpit>` + kernel/initrd) — **NIE jest publikowana jako osobne assety**, siedzi tylko wewnątrz ISO i mieszka w `/porteux/base/`. Zmiana wersji systemu (np. **2.7 → 2.8**) = podmiana bazy z nowego ISO: tryb `--upgrade-base`.

Oba tryby robi ten sam helper z repo, korzystając z [github.com/porteux/porteux/releases](https://github.com/porteux/porteux/releases).

### Krok 0 — sprawdź, w jakiej sesji jesteś

Prawie każdy problem z aktualizacją sprowadza się do jednego: **czy bieżąca sesja ma zamontowaną Twoją warstwę `changes`**. Sprawdzenie zajmuje sekundę:

```bash
cat /proc/cmdline
```

- jest `changes=/porteux` → wszystko OK, helper będzie w `PATH`,
- jest `changes=EXIT:/porteux` → tryb live: zmiany w RAM do czystego zamknięcia,
- **nie ma `changes=` w ogóle** → sesja bez Twojej warstwy: nie ma helpera, nie ma Twoich kont, root ma fabryczne `toor`. Patrz „Rozwiązywanie problemów" niżej.

### Gdzie jest helper

Instalator wgrywa `porteux-update-modules` sam, w fazie finalizacji, w **dwóch** miejscach:

| Ścieżka | Widoczna | Uwaga |
|---|---|---|
| `/usr/local/bin/porteux-update-modules` | tylko w sesji z zamontowaną warstwą `changes` | normalne wywołanie z `PATH` |
| `<nośnik>/porteux/porteux-update-modules` | **zawsze** — to zwykły plik na partycji | ratunek, gdy sesja nie ma warstwy: `bash /mnt/<dev>/porteux/porteux-update-modules --help` |

Obok drugiej kopii leży `porteux/UPDATE-README.txt` z tą samą ściągą. Instalacja zrobiona starszą wersją instalatora ma tylko pierwszą kopię — wtedy pobierz helper ręcznie:

```bash
curl -fsSL https://raw.githubusercontent.com/szoniu/porteux/main/scripts/porteux-update-modules.sh -o /usr/local/bin/porteux-update-modules
chmod +x /usr/local/bin/porteux-update-modules
```

> Uwaga: taki `curl` wykonany w sesji **bez** warstwy `changes` zapisuje plik do tmpfs i zniknie po restarcie.

### Aktualizacja modułów opcjonalnych

```bash
porteux-update-modules                 # tylko sprawdź — listuje co jest nieaktualne
porteux-update-modules --download      # ściągnij nowsze i usuń stare
reboot                                 # nowe moduły aktywują się przy starcie
```

Przykładowy wynik:

```
Updates available:
  MODULE                                INSTALLED  -> LATEST
  08-multilanguage                      20260228   -> 20260823
  05-devel                              20260228   -> 20260823
```

Helper (tryb opcjonalny):
- pyta GitHub API o ostatni release (z retry),
- skanuje **oba** katalogi: `/porteux/modules/` i `/porteux/optional/`, i podmienia moduł w miejscu (nie zmienia tego, czy ładuje się automatycznie),
- dopasowuje moduły po prefiksie nazwy (bez `-current-YYYYMMDD.xzm`),
- pobiera z `curl -C -` (wznowienie przerwanych transferów) i retry,
- usuwa starszą wersję dopiero po udanym pobraniu nowej,
- respektuje `MODULES_DIR=/inna/sciezka` (lub `--modules-dir`), jeśli trzymasz moduły gdzie indziej.

> `--download` podbija **tylko moduły opcjonalne**. Bazy (`000`–`003`) tu nie zobaczysz — nie jest publikowana jako asset. Do zmiany wersji systemu służy `--upgrade-base` poniżej.

### Pełna aktualizacja wersji — np. 2.7 → 2.8 (`--upgrade-base`)

Baza żyje tylko w ISO, więc upgrade wersji pobiera nowe ISO i podmienia zawartość `/porteux/base` **in-place**, zachowując Twoje dane:

```bash
sudo porteux-update-modules --upgrade-base                 # pobierz ISO dla wykrytego wariantu
sudo porteux-update-modules --upgrade-base --iso /mnt/usb  # użyj już zamontowanego ISO/USB (bez pobierania ~1 GB)
```

Co robi:
- wykrywa Twój wariant pulpitu z modułu `003-<pulpit>` w `/porteux/base` i bierze pasujące ISO (kde/xfce/lxqt/…),
- podmienia `000`–`003` + `vmlinuz`/`initrd` (+ `EFI/BOOT`), **zostawia `/porteux/changes` (Twoje dane), `/porteux/modules` i `/porteux/optional`**, zachowuje Twój `porteux.cfg` (czyli `DEFAULT`, `changes=`, `login=`),
- backup starej bazy i plików bootowych → `/porteux/.upgrade-backup-<data>`, a na końcu wypisuje gotowe polecenia **rollbacku** (drukowane także wtedy, gdy upgrade przerwie się w połowie).

> **UEFI: jądro istnieje w DWÓCH kopiach.** Instalacja UEFI trzyma `vmlinuz`/`initrd` zarówno na partycji danych, jak i na ESP — i to z ESP startuje firmware. Podmiana tylko jednej kopii = stare jądro przy nowej bazie, czyli brak pasujących `/lib/modules` i system, który nie wstaje. Helper wykrywa ESP sam (skanuje `/mnt/*`, `/boot/efi`) i aktualizuje obie kopie; gdy maszyna działa w trybie UEFI, a ESP nie da się znaleźć — **przerywa przed tknięciem czegokolwiek** i każe wskazać go jawnie:
>
> ```bash
> sudo porteux-update-modules --upgrade-base --esp /mnt/<esp>   # ESP zamontowany ręcznie
> sudo porteux-update-modules --upgrade-base --no-esp           # instalacja czysto BIOS-owa
> ```

**⚠️ Najważniejsze — skąd to odpalić.** Nie nadpiszesz bazy, która jest właśnie w użyciu (moduły `.xzm` działającego systemu są loop-montowane). Helper sprawdza to przez `losetup` i **odmówi na żywym systemie**. Dwa bezpieczne sposoby — **żaden to nie reinstalacja**:

**1. Ten sam dysk, bez drugiego USB — `copy2ram` dopisany do TWOJEJ etykiety.**

Upstreamowe menu ma osobną pozycję „Copy To RAM", ale ona pochodzi z ISO i **nie zawiera `changes=`** — wejście w nią startuje system bez Twojej warstwy (stąd klasyczne „`porteux-update-modules`: nie ma takiego polecenia"). Instalator od tej wersji wpisuje `changes=` również do niej, ale na starszej instalacji zrób tak:

```
Esc                → pokaż menu (jest ukryte)
strzałki           → podświetl SWOJĄ domyślną pozycję (Graphics Mode)
Tab                → edycja linii startowej
dopisz na końcu:   copy2ram
Enter
```

Po starcie:

```bash
cat /proc/cmdline                          # musi mieć i changes=/porteux, i copy2ram
sudo porteux-update-modules --upgrade-base
```

**2. Z innego medium** — zbootuj z USB z nową wersją (albo dowolnego live z bashem i curlem), wskaż instalkę na dysku:

```bash
sudo bash /mnt/<dev>/porteux/porteux-update-modules --upgrade-base --base-dir /mnt/<dev>/porteux/base
```

Po sukcesie: `reboot`. Jeśli po dużym skoku (glibc/GCC/KDE/Qt) stary overlay `changes` rozjedzie się z nową bazą — użyj rollbacku z komunikatu helpera. (`--force` pomija bramkę live — tylko gdy wiesz, co robisz.)

### Rozwiązywanie problemów

**`porteux-update-modules: command not found` (albo: „nie ma takiego polecenia/pakietu")**

To nie brak pakietu — helper to zwykły skrypt, którego w tej sesji po prostu nie widać. Po kolei:

1. **Czy sesja ma Twoją warstwę?**
   ```bash
   cat /proc/cmdline
   ```
   Brak `changes=` → zbootowałeś etykietę bez persystencji (najczęściej gotową pozycję „Copy To RAM"). Zrestartuj i dopisz `copy2ram` do własnej etykiety przez `Esc` → `Tab` (procedura wyżej).

2. **Czy plik w ogóle jest na dysku?**
   ```bash
   ls -l /mnt/*/porteux/porteux-update-modules /mnt/*/porteux/changes/usr/local/bin/ 2>/dev/null
   ```
   Jest → uruchom po ścieżce bezwzględnej, bez `PATH`:
   ```bash
   sudo bash /mnt/<dev>/porteux/porteux-update-modules --upgrade-base
   ```

3. **Napraw etykiety bootowe raz na zawsze** (instalacja ze starszego instalatora — `changes=` tylko na etykiecie domyślnej):
   ```bash
   sudo porteux-update-modules --fix-persistence
   ```
   Dopisuje `changes=/porteux` do każdej etykiety poza `fresh`/`text-fresh`, w każdej znalezionej kopii `porteux.cfg` (partycja danych **i** ESP), z backupem `porteux.cfg.bak-<data>`; nigdy nie nadpisze configu wynikiem, w którym zabrakłoby etykiet. Gdy znajdzie więcej niż jedną instalację, wypisze listę i poprosi o `--yes` albo o wskazanie jednej: `--cfg /mnt/<dev>/boot/syslinux/porteux.cfg`. Opcjonalnie `LOGIN_USER=<user>` przywraca też autologin.

**Po boocie root ma hasło `toor`, nie ma mojego konta** — ten sam powód: sesja bez warstwy `changes`. Nie instaluj ponownie, tylko zbootuj etykietę z `changes=/porteux` (albo napraw ją `--fix-persistence`).

**`ERR: no 003-<desktop> base module ...`** — helper nie znalazł bazy. Wskaż ją wprost: `--base-dir /mnt/<dev>/porteux/base`.

### Dodatkowe oprogramowanie

Na pojedyncze aplikacje używaj **`porteux-app-store`** (z menu pulpitu) — to GUI do instalacji modułów z repozytorium społeczności. Helper powyżej obsługuje **moduły systemu** (opcjonalne przez `--download`, pełna baza/wersja przez `--upgrade-base`), App Store — resztę.

## Presety

Konfigurację można zapisać i ponownie użyć:

```bash
# Zapisz podczas instalacji (ekran 15)
# Lub użyj istniejącej:
./install.sh --config /root/porteux-preset-20260410.conf
```

Presety są przenośne między maszynami — wartości sprzętowe (GPU, dyski) są re-wykrywane przy imporcie.

## Wznawianie instalacji

Po przerwie w zasilaniu lub błędzie:

```bash
./install.sh --resume    # Skanuje dyski w poszukiwaniu checkpointów
```

Instalator zapamiętuje ukończone fazy i wznawia od ostatniej nieukończonej.

## Zdalna instalacja przez SSH

Możesz uruchomić instalator zdalnie przez SSH — przydatne gdy maszyna docelowa nie ma monitora lub klawiatury.

### Na maszynie docelowej (bootowanej z Live ISO)

```bash
# 1. Ustaw hasło root
passwd root

# 2. Uruchom sshd
# PorteuX Live (Slackware — sysvinit):
chmod +x /etc/rc.d/rc.sshd
/etc/rc.d/rc.sshd start

# Jeśli bootujesz z innego Live ISO (np. Void):
# xbps-install -Sy openssh && ssh-keygen -A
# echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
# ln -sf /etc/sv/sshd /var/service/sshd

# 3. Zezwól na logowanie root (jeśli zablokowane)
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
/etc/rc.d/rc.sshd restart

# 4. Sprawdź IP
ip -4 addr show | grep inet

# 5. Zweryfikuj
ss -tlnp | grep 22    # powinno: LISTEN
```

### Z innego komputera

```bash
ssh root@<IP-maszyny-docelowej>
git clone https://github.com/szoniu/porteux.git
cd porteux
./install.sh
```

### Użyj tmux — ochrona przed zerwaniem SSH

**Ważne:** Jeśli połączenie SSH się zerwie, instalacja w zwykłej sesji zostanie przerwana. **Zawsze uruchamiaj installer w tmux:**

```bash
# Na maszynie docelowej (po połączeniu SSH):
# Jeśli tmux nie jest zainstalowany: installpkg tmux (Slackware) lub pobierz statyczną wersję
tmux new -s install

# Sklonuj i uruchom
git clone https://github.com/szoniu/porteux.git
cd porteux
./install.sh
```

Jeśli połączenie SSH się zerwie:
```bash
# Połącz się ponownie
ssh root@<IP>
tmux attach -t install
```

Instalacja nadal działa w tle — nic nie stracisz.

### Monitorowanie z drugiego połączenia

```bash
ssh root@<IP>

# Logi w czasie rzeczywistym
tail -f /tmp/porteux-installer.log
```

### Rozwiązywanie problemów z SSH

- **`Connection reset by peer`** — sshd nie działa. Sprawdź: `/etc/rc.d/rc.sshd status` (Slackware) lub `ss -tlnp | grep 22`.
- **`Permission denied (publickey)`** — dodaj `PermitRootLogin yes` do `/etc/ssh/sshd_config` i restartuj sshd.
- **`Permission denied, please try again`** — hasło nie ustawione. Uruchom `passwd root` na maszynie docelowej.
- **Brak tmux na Live ISO** — użyj `screen` jako alternatywę, lub pobierz statyczny tmux: `curl -LO https://github.com/tmux/tmux/releases/...`

## Menu naprawcze

Gdy komenda zawiedzie, instalator wyświetla menu:
- **Retry** — powtórz komendę
- **Shell** — otwórz shell do diagnostyki
- **Continue** — pomiń i kontynuuj
- **Log** — pokaż log
- **Abort** — przerwij instalację

## Backend TUI

Instalator obsługuje 3 backendy (priorytet: gum > dialog > whiptail):
- **gum** — dołączony w repo (`data/gum.tar.gz`), zero zależności
- **dialog** — jeśli zainstalowany w systemie Live
- **whiptail** — fallback

## Struktura projektu

```
install.sh          — Główny orkiestrator
configure.sh        — Wrapper: tylko konfiguracja
lib/                — Moduły biblioteczne (nigdy nie uruchamiaj bezpośrednio)
tui/                — Ekrany interaktywne (return 0=dalej, 1=wstecz, 2=przerwij)
data/               — Bazy danych, zasoby statyczne (gum, dialogrc, baza GPU, mirrory)
scripts/            — Narzędzia poinstalacyjne (porteux-update-modules)
presets/            — Przykładowe konfiguracje
hooks/              — Przykłady hooków (before_*/after_*)
tests/              — Testy (standalone bash)
docs/               — Notatki (TESTING-NOTES.md)
CLAUDE.md           — Kontekst techniczny dla Claude Code
```

## FAQ

**Jak długo trwa instalacja?**
~5-15 minut (zależnie od prędkości internetu do pobrania ISO ~500 MB-1 GB).

**Czy mogę zainstalować na VM?**
Tak, QEMU/KVM i VirtualBox są obsługiwane. W VM nie potrzebujesz Live USB — uruchom instalator bezpośrednio z terminala.

**Czym się różni od oficjalnego instalatora PorteuX?**
Oficjalny "instalator" to prosty skrypt kopiujący pliki na USB. Ten instalator zapewnia pełny wizard TUI z partycjonowaniem, dual-boot, detekcją sprzętu, persystencją i wiele więcej.

**Czy obsługuje Secure Boot?**
Nie w obecnej wersji. PorteuX oficjalnie nie wspiera Secure Boot. Wyłącz Secure Boot w BIOS/UEFI.

**Co to jest "Copy to RAM"?**
Tryb, w którym cała baza systemu jest kopiowana do RAM-u przy starcie. Po załadowaniu moduły `.xzm` na dysku nie są już trzymane otwarte — dlatego to jedyny sposób na `--upgrade-base` bez drugiego nośnika. Wymaga 4+ GB RAM. **`copy2ram` to nie jest tryb persystencji:** etykieta bootowa musi nieść również `changes=/porteux`, inaczej sesja wstanie bez Twojej warstwy (bez kont, bez helpera aktualizacji). Przy `changes=/porteux` nośnik pozostaje zamontowany, bo zapisy idą na dysk na bieżąco.
