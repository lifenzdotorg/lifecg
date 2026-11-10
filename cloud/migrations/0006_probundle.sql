-- Legacy ProPresenter support during the changeover: campuses that still build notes in ProPresenter get a
-- .probundle emailed with each push (built in the portal from the campus theme).
ALTER TABLE campuses ADD COLUMN send_probundle INTEGER NOT NULL DEFAULT 0;
ALTER TABLE service_notes ADD COLUMN probundle_key TEXT;
ALTER TABLE service_notes ADD COLUMN probundle_name TEXT;
