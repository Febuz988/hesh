# HESH — Specifiche funzionali dell’app

Versione: 1.0 · Data: 7 novembre 2026

## 1. Visione

HESH è un’app di messaggistica privata per persone che scelgono di comunicare all’interno di un cerchio di fiducia. L’identità si basa sul nome utente, senza numero di cellulare né indirizzo email. L’esperienza comprende messaggi, gruppi, chiamate, videochiamate, condivisione volontaria della posizione e SOS al gruppo.

L’interfaccia combina liquid glass, pulsanti arrotondati ed estetica cyberpunk, con versioni chiara e scura e temi originali HESH.

Questo documento descrive il prodotto previsto. Il prototipo attuale è un mockup interattivo: non implementa un servizio reale di comunicazione, cifratura, autenticazione, localizzazione o gestione degli inviti.

## 2. Accesso rigorosamente su invito

### Regola fondamentale

**L’accesso all’app è vietato a chiunque non sia stato invitato e ammesso tramite un link oppure un QR code generato da HESH.**

Non sono consentiti registrazione pubblica, accesso come ospite, accesso anonimo ai contenuti o ingresso mediante il solo nome utente. Conoscere un indirizzo di pagina, un identificativo di gruppo o un nome utente non concede alcun diritto di accesso.

La pagina di ingresso può mostrare soltanto le informazioni necessarie per autenticarsi o riscattare un invito. Chat, profili, gruppi, allegati e posizioni richiedono sempre autenticazione e autorizzazione.

### Forme di invito ammesse

- **Link generato dall’app:** contiene un token di invito non prevedibile.
- **QR code generato dall’app:** rappresenta un link o token di invito valido prodotto da HESH.
- Entrambe le forme devono essere create dall’app e verificate dal servizio HESH. Una stringa inventata, un QR arbitrario o un codice contraffatto non devono consentire l’ingresso.
- Link e QR possono rappresentare lo stesso invito: il riscatto di una forma deve consumare anche l’altra quando l’invito è monouso.

Il nome utente serve per identificare persone già ammesse e inviare richieste di contatto. **Non sostituisce il link o il QR per ottenere accesso iniziale.** Questa regola aggiorna il precedente concept di inviti tramite nome utente.

### Ciclo di vita dell’invito

1. Un membro autorizzato genera un invito dall’app.
2. HESH associa all’invito emittente, scadenza, destinatario quando previsto e ambito di accesso.
3. Il destinatario apre il link o scansiona il QR.
4. Il servizio controlla validità, scadenza, revoca e precedente utilizzo.
5. Il destinatario sceglie un nome utente e configura il metodo di autenticazione.
6. HESH completa il riscatto in modo atomico: lo stesso invito non può creare più account se monouso.
7. Il nuovo membro accede soltanto agli spazi per i quali è autorizzato.

### Requisiti di sicurezza degli inviti

- Inviti monouso come impostazione iniziale proposta.
- Scadenza predefinita proposta: 24 ore, da confermare per il prodotto.
- Revoca da parte dell’emittente o di un amministratore autorizzato.
- Elenco degli inviti con stato: attivo, utilizzato, scaduto o revocato.
- Token generati con casualità crittografica; conservazione lato server mediante rappresentazione non direttamente riutilizzabile.
- Nessun token completo nei log applicativi o negli strumenti di analisi.
- Protezione da tentativi ripetuti, enumerazione e abuso della generazione.
- Verifica lato server: nascondere un pulsante o una pagina non costituisce controllo di accesso.
- Invito all’app e invito a un gruppo hanno ambiti distinti: essere ammessi a HESH non concede accesso a tutti i gruppi.
- Gli account sospesi o eliminati non possono usare vecchie sessioni per rientrare.

Un link o QR trasferibile prova il possesso dell’invito, non l’identità della persona. Per limitare gli inviti inoltrati, prevedere approvazione dell’emittente al riscatto oppure associazione a un’identità verificata con un canale concordato. La scelta va definita prima del rilascio.

Il primo account e gli eventuali account di amministrazione richiedono una procedura iniziale controllata; non deve esistere un percorso pubblico alternativo alla regola di invito.

## 3. Profilo e identità

- Nome utente unico, obbligatorio.
- Nessun numero di telefono richiesto o usato per l’accesso.
- Nessuna email richiesta o usata per l’accesso.
- Foto profilo personalizzabile.
- Compleanno facoltativo, con visibilità configurabile.
- Gestione del nome utente e dei dati facoltativi.
- Richieste di contatto tra membri ammessi, con accettazione, rifiuto e blocco.
- Nessuna rubrica pubblica liberamente consultabile da persone esterne.
- Recupero account senza SMS o email: progettare una procedura basata su dispositivi fidati e/o codice di recupero custodito dall’utente.

## 4. Messaggistica

- Chat individuali.
- Invio e ricezione di messaggi di testo ed emoji.
- Elenco delle conversazioni, ricerca e filtri per gruppi e messaggi non letti.
- Indicatori di invio, consegna e lettura, subordinati alle impostazioni di privacy.
- Cancellazione dei propri messaggi.
- Distinzione tra eliminazione locale ed eliminazione per tutti, con finestra temporale e comportamento offline da definire.
- Messaggi effimeri con durata configurabile: disattivati, 1 ora, 24 ore o 7 giorni come opzioni iniziali.
- Avviso quando cambia la durata dei messaggi effimeri.
- Gestione coerente della cancellazione e della scadenza sui dispositivi autorizzati.

La cancellazione non può garantire la rimozione di screenshot, copie esportate o contenuti acquisiti dal destinatario fuori dall’app.

## 5. Chat segreta

La cifratura end-to-end deve essere prevista per tutte le conversazioni. La chat segreta aggiunge restrizioni di conservazione e disponibilità.

- Attivazione esplicita di una conversazione segreta.
- Messaggi effimeri configurabili.
- Anteprime delle notifiche nascoste.
- Disponibilità limitata ai dispositivi partecipanti autorizzati.
- Nessuna sincronizzazione cloud della cronologia segreta nel concept.
- Possibilità di proteggere l’apertura con autenticazione locale.
- Indicazione visiva chiara della modalità segreta.
- Verifica dell’identità e delle chiavi dei partecipanti.

Non promettere blocco assoluto di screenshot o registrazioni dello schermo: le possibilità dipendono dal sistema operativo e non impediscono acquisizioni esterne.

## 6. Gruppi

- Creazione di gruppi privati con nome e immagine.
- Selezione dei membri e invito attraverso i flussi autorizzati.
- Ruoli di proprietario, amministratore e membro, con permessi da finalizzare.
- Gestione degli ingressi, rimozione membri e uscita volontaria.
- Nessun gruppo pubblico aperto a utenti non ammessi.
- Impostazioni di notifiche, durata dei messaggi e condivisione della posizione per gruppo.
- Possibilità di designare un gruppo come cerchio familiare e destinatario SOS.
- Cambi di appartenenza gestiti anche a livello di chiavi e autorizzazioni.
- La visibilità della cronologia precedente all’ingresso deve essere una scelta esplicita del prodotto.

## 7. Chiamate e videochiamate

- Chiamate audio individuali.
- Videochiamate individuali.
- Schermate di chiamata in ingresso, chiamata in corso, chiamata persa e termine chiamata.
- Accettazione, rifiuto e interruzione.
- Attivazione e disattivazione di microfono e videocamera.
- Selezione di ingresso e uscita audio quando supportata.
- Richiesta dei permessi di sistema soltanto quando necessari.
- Notifiche e suonerie configurabili.
- Cifratura end-to-end dei flussi multimediali come requisito del prodotto.
- Chiamate e videochiamate di gruppo: estensione prevista, da definire per la prima versione.

La scelta di Signal Protocol per la messaggistica non definisce da sola l’architettura di trasporto e cifratura delle chiamate: questa richiede progettazione dedicata.

## 8. Allegati e contenuti in chat

| Contenuto | Comportamento previsto |
| --- | --- |
| Foto | Scelta dalla libreria o acquisizione dalla fotocamera, anteprima e invio. |
| Video | Selezione o registrazione, anteprima e invio. |
| Audio | Invio di file audio con riproduzione in chat. |
| Messaggio vocale | Registrazione, ascolto prima dell’invio, annullamento e invio. |
| File | Allegato con nome, tipo, dimensione e download autorizzato. |
| Regalo | Biglietto o contenuto regalo virtuale; natura e contenuti da definire. |
| Posizione | Invio di un punto oppure condivisione temporanea della posizione. |

Requisiti comuni:

- Cifratura degli allegati prima del caricamento e accesso riservato ai destinatari autorizzati.
- Avanzamento, annullamento e gestione degli errori di trasferimento.
- Limiti di dimensione, formati e conservazione da definire.
- Gestione dei permessi per foto, videocamera, microfono e posizione.
- Il regalo iniziale non comporta pagamenti, trasferimenti di denaro o acquisti.

## 9. Mappa famiglia e posizione

- Mappa del cerchio familiare.
- Posizione dei soli membri che hanno scelto di condividerla.
- Condivisione disattivata fino al consenso esplicito.
- Selezione dei destinatari e della durata della condivisione.
- Interruzione immediata della condivisione futura.
- Invio di posizione singola distinto dal tracciamento temporaneo in tempo reale.
- Indicazione dell’ultimo aggiornamento e dell’eventuale posizione non aggiornata.
- Gestione di permessi negati, GPS indisponibile e dispositivo offline.
- Nessun accesso alla posizione mediante il solo possesso di un nome utente o di un invito all’app.
- Visibilità configurabile in Privacy e sicurezza.
- Cifratura e minimizzazione dei dati di localizzazione come requisiti di progettazione.

## 10. SOS al gruppo

- Pulsante SOS riconoscibile e facilmente raggiungibile.
- Scelta esplicita del gruppo destinatario.
- Conferma o pressione prolungata per ridurre gli invii accidentali; modalità da validare.
- Invio di un messaggio di allerta al gruppo selezionato.
- Inclusione della posizione soltanto se autorizzata e disponibile.
- Invio dell’allerta anche senza posizione, segnalando che non è disponibile.
- Stato di invio chiaro: in attesa, inviato, consegnato o errore.
- Azione per comunicare al gruppo che l’emergenza è rientrata.

L’SOS di HESH avvisa il gruppo. Non implica una chiamata automatica ai servizi di emergenza e non garantisce ricezione immediata, risposta dei destinatari o disponibilità della rete.

## 11. Dispositivi e sessioni

- Elenco dei dispositivi collegati: PC/Mac, iPad/tablet e telefoni.
- Nome e tipo del dispositivo, sessione corrente e ultimo utilizzo.
- Aggiunta di un dispositivo tramite autenticazione e approvazione sicura, eventualmente con QR di associazione distinto dagli inviti all’app.
- Revoca di una singola sessione.
- Disconnessione di tutti gli altri dispositivi.
- Avviso quando viene associato un nuovo dispositivo.
- Revoca delle credenziali di sessione e cessazione dell’accesso ai nuovi dati dopo la disconnessione.
- Politica di sincronizzazione della cronologia da definire, con regole specifiche per le chat segrete.

Le località mostrate per le sessioni devono essere dichiarate approssimative quando derivate dall’indirizzo IP.

## 12. Notifiche e suoni

- Attivazione separata delle notifiche per messaggi, gruppi e chiamate.
- Silenziamento delle singole conversazioni.
- Controllo delle anteprime del testo nelle notifiche.
- Suoni interni all’app attivabili o disattivabili.
- Suonerie e suoni di notifica selezionabili.
- Prime proposte sonore HESH: Pulse, Glass ed Echo.
- Opzione silenziosa.
- Comportamento coerente con i permessi e le modalità di concentrazione del sistema operativo.
- Contenuti sensibili delle chat segrete esclusi dalle anteprime.

## 13. Privacy e sicurezza

### Visibilità delle informazioni

Configurazione separata per:

- Ultimo accesso.
- Stato in linea.
- Posizione.
- Foto profilo.
- Compleanno.

Opzioni iniziali:

- Il mio cerchio.
- Solo contatti scelti, con selezione effettiva dei destinatari.
- Nessuno.

La modifica delle preferenze deve essere applicata alle risposte del servizio e alle sottoscrizioni in tempo reale, non soltanto all’interfaccia.

### Protezione dell’accesso

- Passkey per autenticarsi, dove supportate.
- Face ID o impronta digitale per sbloccare localmente l’app, secondo le capacità del dispositivo.
- Blocco automatico dopo inattività.
- Metodo di recupero e alternativa sicura per dispositivi privi di biometria.
- Richieste di contatto controllabili e utenti bloccabili.
- Revoca delle sessioni e gestione dei dispositivi fidati.

HESH non deve raccogliere immagini del volto o impronte: la verifica biometrica è delegata al sistema operativo. Sblocco biometrico locale, autenticazione tramite passkey e cifratura dei messaggi sono funzioni distinte.

### Cifratura e gestione delle chiavi

- Cifratura end-to-end per chat individuali e gruppi come requisito.
- Signal Protocol come base prevista per la messaggistica, con integrazione e compatibilità da verificare durante lo sviluppo.
- Verifica delle chiavi o del codice di sicurezza dei contatti.
- Avvisi per cambiamenti rilevanti dell’identità crittografica o dei dispositivi.
- Conservazione delle chiavi nei meccanismi sicuri disponibili sul dispositivo.
- Progettazione dedicata per gruppi, allegati, multi-dispositivo, chiamate, backup e recupero.
- Nessuna promessa di accesso in chiaro ai messaggi da parte degli amministratori del servizio.
- Analisi esplicita dei metadati raccolti: E2E non significa assenza automatica di metadati.

Prima del rilascio servono una progettazione delle minacce e una verifica indipendente dell’implementazione crittografica.

## 14. Aspetto e temi

- Modalità chiara: **Liquid Daylight**.
- Modalità scura: **Dark Matter**.
- Cambio rapido del tema.
- Superfici liquid glass, trasparenze controllate e bottoni arrotondati.
- Estetica cyberpunk riconoscibile, con contrasto e leggibilità adeguati.
- Collezione di temi originali da creare: **HESH Originals**.
- Prime palette concept: Acid, Ultraviolet, Ice e Rose.
- Temi applicati a chat, navigazione, impostazioni e componenti interattivi.
- Layout adattabili a telefono, tablet e desktop.
- Rispetto delle preferenze di accessibilità, incluse riduzione delle animazioni e dimensioni del testo.

## 15. Eliminazione account

- Voce dedicata nelle impostazioni.
- Spiegazione delle conseguenze prima della conferma.
- Nuova verifica dell’identità per l’azione definitiva.
- Conferma esplicita, per esempio digitando ELIMINA.
- Revoca delle sessioni, delle associazioni dispositivo e degli inviti attivi emessi dall’account secondo la politica scelta.
- Rimozione del profilo e cessazione della condivisione della posizione.
- Gestione dei gruppi di cui l’utente è proprietario prima dell’uscita definitiva.
- Politica trasparente su messaggi già consegnati, allegati, copie presenti sui dispositivi altrui, backup e tempi di cancellazione dei dati del servizio.
- Eventuale nuovo ingresso consentito soltanto attraverso un nuovo invito valido.

Il prodotto non deve dichiarare che l’eliminazione dell’account cancella automaticamente ogni copia dei messaggi dai dispositivi dei destinatari.

## 16. Schermate previste

1. Ingresso riservato e riscatto invito.
2. Registrazione tramite nome utente e configurazione accesso.
3. Elenco chat e ricerca.
4. Conversazione individuale.
5. Conversazione di gruppo.
6. Chat segreta.
7. Menu allegati e composizione di contenuti.
8. Chiamata audio e videochiamata.
9. Creazione gruppo e gestione membri.
10. Generazione, visualizzazione e revoca di link/QR di invito.
11. Scansione QR di invito.
12. Mappa famiglia e gestione condivisione.
13. Invio SOS e stato dell’allerta.
14. Profilo e nome utente.
15. Dispositivi collegati.
16. Notifiche e suoni.
17. Privacy e sicurezza.
18. Passkey, biometria e recupero account.
19. Aspetto e temi.
20. Eliminazione account.

## 17. Stato attuale del prototipo

| Area | Stato del mockup |
| --- | --- |
| Nome HESH, modalità chiara e scura | Presenti. |
| Chat e gruppi | Interazioni locali dimostrative, senza servizio di messaggistica. |
| Cancellazione messaggi | Rimozione locale nel mockup. |
| Chat segreta e messaggi effimeri | Interfaccia simulata; nessuna sicurezza aggiuntiva reale. |
| Chiamate e videochiamate | Schermate demo; nessuna connessione o acquisizione multimediale. |
| Allegati e vocali | Rappresentazioni dimostrative; nessun trasferimento o registrazione reale. |
| QR e inviti | Concept grafico; QR non scansionabile e nessuna ammissione reale. |
| Inviti iniziali tramite link/QR generati dall’app | Requisito aggiornato in questo documento, da implementare. |
| Mappa e SOS | Dati fittizi e messaggi demo. |
| Dispositivi | Lista dimostrativa; non corrisponde alle sessioni reali. |
| Privacy, notifiche e suoni | Controlli di interfaccia; non applicano politiche reali del servizio. |
| Face ID, impronta e passkey | Simulazioni, non autenticazione reale. |
| Signal Protocol / E2E | Non implementati. |
| Eliminazione account | Conferma simulata; nessun account reale viene eliminato. |

L’accesso privato al sito che ospita il mockup è distinto dal futuro sistema di inviti e autenticazione di HESH.

## 18. Criteri di accettazione prioritari per il prodotto

- Un visitatore senza invito valido non può registrarsi né accedere a dati privati.
- Il solo nome utente non consente l’ammissione all’app.
- Inviti scaduti, revocati, contraffatti o già consumati vengono rifiutati.
- Un link e il QR dello stesso invito non possono essere riscattati due volte se monouso, anche con richieste contemporanee.
- Ogni richiesta a chat, gruppi, allegati e posizioni verifica l’autorizzazione sul server.
- Un membro non può consultare gruppi o contenuti ai quali non appartiene.
- La revoca di un dispositivo impedisce nuovi accessi con la sessione revocata.
- Nessuna posizione viene condivisa senza consenso e destinatari definiti.
- Le scelte di visibilità producono effetti reali sui dati distribuiti.
- Le funzioni pubblicizzate come E2E vengono verificate con test e revisione dell’implementazione.
- Gli stati di errore non vengono presentati come consegne o chiamate riuscite.
- Chiaro e scuro mantengono leggibilità e accessibilità delle azioni principali.

## 19. Decidiamo insieme

- Chi può generare inviti e con quali limiti.
- Scadenza definitiva e regole di approvazione degli inviti inoltrati.
- Procedura controllata per il primo membro.
- Recupero account senza email o telefono.
- Piattaforme native e disponibilità del client web.
- Architettura E2E, librerie, compatibilità e revisione della sicurezza.
- Regole della cronologia su nuovi dispositivi e nei gruppi.
- Limiti per allegati e comportamento della cancellazione per tutti.
- Chiamate di gruppo nella prima versione o in una fase successiva.
- Natura dei regali virtuali.
- Durata e conservazione dei dati di posizione.
- Regole per SOS offline e notifiche urgenti, senza promesse di consegna garantita.
- Politiche di backup, conservazione ed eliminazione account.
- Realizzazione della collezione grafica e sonora originale HESH.