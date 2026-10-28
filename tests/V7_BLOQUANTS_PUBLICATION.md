# JKBat V7 — verrou de publication (28 octobre 2026)

**Statut : NO GO — ne pas déployer sur Supabase, ne pas remplacer les APK officielles.**

Cette branche contient un SQL candidat **non destructif** et des tests PostgreSQL 17
sur données fictives. Elle n'intègre pas encore le code source final des trois applications.

## Contrôles confirmés

- Le workflow « JKBat V7 - verification du vrai SQL sur PostgreSQL fictif » est passé
  (run GitHub `40670831554`). Il teste des rôles, le retrait d'une tâche, la
  conservation d'un rapport et d'une photo, le refus d'un compte non habilité,
  le refus d'une suppression physique et la restauration administrative.
- L'application Équipe V7 TEST a été compilée et s'ouvre sur le téléphone.
  **Le retrait reste désactivé** jusqu'au déploiement serveur.
- Le dernier contrôle du projet Supabase n'indique **aucune table de retrait durable V7**.

## Quatre incompatibilités de publication découvertes sur les sources candidates

1. **JKBat Pro est volontairement en lecture seule.** Son `index.html` charge
   `v7-readonly-guard.js` en premier : ce verrou bloque les requêtes Cloud
   d'écriture, y compris des opérations métier normales. `v74-backend-bridge.js`
   a également `serverReady:false` et `authorized:false`. **On ne peut pas
   publier cette source comme version Pro officielle.**
2. **Contrat RPC incomplet.** Le pont Pro appelle `jkbat_v73_state_team`,
   `jkbat_v73_reassign_team`, `jkbat_v73_restore_client_appointment` et
   `jkbat_v74_state_client`. Cette dernière RPC n'est pas définie dans la migration
   V73 incluse. La source Équipe appelle
   `jkbat_v7_withdraw_own_assignment`, également absente de V73 ; elle existe
   uniquement dans un candidat de génération ultérieure.
3. **Ancienne migration V73 NON SÛRE telle quelle.** Sa fonction
   `jkbat_v73_team_deleted` est déclenchée **APRÈS DELETE** et n'empêche pas
   l'effacement de `jkbat_staff_assignments`. Or les tables rapports/photos
   ont des FK avec `ON DELETE CASCADE`. Écrire un marqueur après coup
   **n'empêche pas la disparition des pièces jointes**. Ne pas déployer ce SQL.
4. **Tests PostgreSQL isolés ≠ intégration Supabase.** Les véritables triggers
   Client, stock, signatures, notifications, anciennes APK et synchronisation
   `jkbat_sync_store` ne sont pas reproduits entièrement dans le banc d'essai.

## Conditions du prochain « GO »

- Une seule migration compatible avec les RPC **effectivement utilisées**
  par Pro/Client/Équipe, incluant le verrou de suppression **AVANT DELETE**.
- Sauvegarde restaurable et audit des droits/RLS, puis intégration et essai des
  vrais triggers historiques dans un environnement non productif.
- Suppression du verrou Pro **uniquement dans le build officiel validé** ;
  l'activer prématurément dans le test serait dangereux.
- Vérification de bout en bout sur trois APK **non officielles**, après installation
  serveur contrôlée et confirmation que devis, paiements, signatures,
  documents, planning et notifications restent inchangés.
- Publication de trois APK officielles seulement après ces contrôles.

**Aucun SQL appliqué à la production, aucun nouveau service payant.**
