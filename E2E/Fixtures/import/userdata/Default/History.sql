-- Builds this profile's History database (the e2e harness runs it into a file named History in a copy of this
-- folder, then deletes this script). The columns are the subset of Chromium's schema the importer reads.
-- Times are WebKit microseconds (since 1601); 13344473600000000 is 2023-11-14 22:13:20 UTC.
CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER,
  typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, from_visit INTEGER,
  transition INTEGER, visit_duration INTEGER);
INSERT INTO urls (id, url, title) VALUES (1, 'https://example.org/default-arc', 'Default profile page');
INSERT INTO visits (url, visit_time, transition) VALUES (1, 13344473600000000, 0);
INSERT INTO visits (url, visit_time, transition) VALUES (1, 13344473660000000, 805306369);
