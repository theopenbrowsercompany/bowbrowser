-- Builds this profile's History database (see Default/History.sql). Three visits come across: two to zephyr and
-- one to quokka; the chrome:// page, the subframe load (transition 3) and the reload (transition 8) do not.
CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER,
  typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, from_visit INTEGER,
  transition INTEGER, visit_duration INTEGER);
INSERT INTO urls (id, url, title) VALUES (1, 'https://example.com/zephyr-arc', 'Zephyr imported page');
INSERT INTO urls (id, url, title) VALUES (2, 'https://example.com/quokka-arc', 'Quokka notes');
INSERT INTO urls (id, url, title) VALUES (3, 'chrome://settings/', 'Settings');
INSERT INTO urls (id, url, title) VALUES (4, 'https://ads.example.com/frame', '');
INSERT INTO visits (url, visit_time, transition) VALUES (1, 13344473600000000, 805306369);
INSERT INTO visits (url, visit_time, transition) VALUES (1, 13344473660000000, 0);
INSERT INTO visits (url, visit_time, transition) VALUES (2, 13344473720000000, 0);
INSERT INTO visits (url, visit_time, transition) VALUES (3, 13344473780000000, 1);
INSERT INTO visits (url, visit_time, transition) VALUES (4, 13344473840000000, 3);
INSERT INTO visits (url, visit_time, transition) VALUES (2, 13344473900000000, 8);
