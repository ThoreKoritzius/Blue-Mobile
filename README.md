# Blue Mobile

Flutter client for the Blue diary/memory backend.

## Features
- 5-tab bottom navigation: Day, Calendar, Runs, Chat, Map
- Day editor with hero image, gallery upload, people/tags chips, diary text
- GraphQL integration for stories/files/runs/calendar/chat
- Streaming chat via GraphQL subscription with completion fallback
- Map view with Mapbox tiles, run polylines, and photo markers

## Backend assumptions
- GraphQL endpoint: `/api/graphql` via gateway domain (default: `https://blue.the-centaurus.com`)
- Static assets:
  - `/api/images/*`
  - `/api/runs/*`
- Auth flow:
  - First: Google OAuth via oauth2-proxy (`/oauth2/sign_in`)
  - Then: backend app login (`auth.login` username/password)
  - Android callback bridge: `/api/auth/mobile/complete` -> `blueapp://oauth-callback`

## Run

```bash
cd Blue-Mobile
flutter pub get
flutter run \
  --dart-define=BACKEND_URL=https://blue.the-centaurus.com \
  --dart-define=USE_OAUTH_GATEWAY=true \
  --dart-define=MAPBOX_ACCESS_TOKEN=YOUR_TOKEN
```

## Validate

```bash
flutter analyze
flutter test
```
