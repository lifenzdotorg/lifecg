-- The speaker's full notes (PDF or Word), uploaded with a message and sent with each push as "Notes"
-- next to the generated "Slides Preview" PDF. A push keeps the file it was sent with.
ALTER TABLE messages ADD COLUMN notes_key TEXT;
ALTER TABLE messages ADD COLUMN notes_name TEXT;
ALTER TABLE messages ADD COLUMN notes_type TEXT;
ALTER TABLE messages ADD COLUMN notes_size INTEGER;
ALTER TABLE service_notes ADD COLUMN notes_key TEXT;
ALTER TABLE service_notes ADD COLUMN notes_name TEXT;
ALTER TABLE service_notes ADD COLUMN notes_type TEXT;
