-- Campuses. Recipients and users are added in the portal (no email addresses in the repo).
INSERT INTO campuses (id, name, default_theme_id, sort) VALUES
  ('central',  'Central',  'central', 1),
  ('north',    'North',    'central', 2),
  ('south',    'South',    'central', 3),
  ('west',     'West',     'west',    4),
  ('east',     'East',     'central', 5),
  ('tauranga', 'Tauranga', 'central', 6),
  ('chapel',   'Chapel',   'central', 7);
