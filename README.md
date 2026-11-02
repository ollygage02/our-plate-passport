# Our Plate Passport

A food passport for a group of friends: must-try dishes for 37 countries, a researched
Cologne guide, everyone's meal photos with ratings, and a map of where you've eaten.

It's a plain static website (no build step) that uses Supabase for logins, the database and photos.

## Files
- `index.html` – the whole app
- `config.js` – your Supabase project URL and public (anon/publishable) key
- `supabase/setup.sql` – creates the tables, security rules and photo storage. Run it once in the Supabase SQL editor.
- `manifest.webmanifest`, icons – so it can be added to a phone's home screen

## Setup
1. Supabase: create a project, run `supabase/setup.sql` (with your email on the last line).
2. Supabase > Authentication > Sign In / Providers > Email: turn **off** "Confirm email".
3. Supabase > Authentication > URL Configuration: set Site URL to the Vercel address.
4. Put the project URL and anon/publishable key in `config.js`.
5. Vercel: import this GitHub repository and deploy. Every push to `main` redeploys automatically.

## Privacy
Only email addresses in the `members` table can create an account or see anything.
Add friends from the app (Passport > Group members). Photos are re-encoded in the
browser before upload, which strips location data.
