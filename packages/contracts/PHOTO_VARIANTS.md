# Photo variants — R2 `photos/{recipeId}/{variant}.jpg`
- `original` — as-uploaded, max 12MB, private.
- `1024` — longest edge 1024px, q80 JPEG, for detail view.
- `thumb` — 256px square crop, q70, for lists.
- Signed GET URLs, expiry <15min. Dedup by SHA-256: same hash reuses keys.
- EXIF stripped. Content-Type `image/jpeg`.
