# Todo app in Flutter

Obiettivo: una piccola app Flutter per Windows che gestisce una lista di cose da fare,
con salvataggio locale. Codice pulito, test per la logica.

## Struttura del progetto
Crea il progetto Flutter `todo_app` (solo piattaforma Windows) nella cartella di lavoro.
Organizza `lib/` in `models/`, `data/` e `ui/`. Verifica che `flutter analyze` sia pulito.

## Modello e persistenza
Crea il modello `Todo` (id, titolo, completato, data di creazione) con serializzazione JSON.
Salva e carica la lista da un file JSON nella cartella documenti dell'utente.
Scrivi test unitari per serializzazione e repository.

## Interfaccia
Schermata principale con lista, campo per aggiungere, checkbox per completare e
swipe per eliminare. Filtro: tutti / da fare / completati.

## Rifinitura
Tema chiaro/scuro che segue il sistema, stato vuoto illustrato, README con istruzioni.
