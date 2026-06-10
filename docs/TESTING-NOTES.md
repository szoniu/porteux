# Notatki testowe — rodzina installerów i testy na sprzęcie

## Rodzina installerów: współdzielony `lib/dialog.sh`

`~/dev` zawiera 6 bliźniaczych installerów TUI z tego samego szablonu: **alpine, chimeraos,
gentoo, nixos, porteux, void**. Mają (niemal) identyczny `lib/dialog.sh` (wrapper
gum/dialog/whiptail) i tę samą architekturę screen/wizard.

**Konwencja:** `dialog_menu "tytuł" tag desc ...` (pary), `dialog_radiolist`/`dialog_checklist
"tytuł" tag desc state ...` (trójki). **NIE ma argumentu prompt/text** — znaczenie niesie tytuł.
Dodatkowy prompt jako `$2` psuje parzystość elementów; pod `set -u` gałąź gum robi
`${items[i+1]}` poza zakresem → "unbound variable" → ekran abortuje i zwraca TUI_BACK (wygląda
jak wizard „odbijający" o ekran wstecz). Audyt 2026-05-25: tylko porteux miał odchył (10 wywołań,
naprawione); pozostałe 5 czyste.

**Jak stosować:** fix w kodzie współdzielonym (dialog.sh, utils.sh, logika wizarda) → sprawdź,
czy pozostałe installery nie potrzebują tego samego. Debug „zaciętego/odbijającego" wizarda →
najpierw podejrzewaj niezgodność liczby argumentów w `dialog_*`, nie backend TUI.

## gum vs konsola

gum (bundlowany v0.17.0, bubbletea) jest kruchy na surowym `TERM=linux` i egzotycznych
terminalach (ghostty/kitty) — odpowiedzi na terminal queries potrafią wstrzyknąć fantomowe ESC.
Escape hatche w porteux: `PORTEUX_TUI=gum|dialog|whiptail` + auto-fallback `TERM` dla backendów
ncurses. Na żywej konsoli (`TERM=linux`) niezawodny wariant: `PORTEUX_TUI=dialog ./install.sh`.

## Pętla testów na realnym sprzęcie (pass od 2026-05-25)

- Boot z live, sterowanie często po SSH z ghostty; fixy lecą na `main` i live maszyna robi
  `git pull` — uzgodniona pętla tego passa testowego.
- Log: `/tmp/porteux-installer.log` (tylko e*/ERR, bez widżetów TUI) — `tail` po SSH.
- Instalator wymazuje dyski — fixy muszą być bezpieczne dla re-runa (`--resume`).
- Naprawione w tym passie: `has_network` tylko-ICMP (LAN blokuje ping) → fallback HTTPS;
  crash backendów ncurses na `TERM=xterm-ghostty` (brak terminfo) → auto-fallback `TERM`;
  „odbijający" wizard = nadmiarowy prompt w `dialog_*` (patrz wyżej).
