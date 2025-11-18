
```
docker build \
  --build-arg APPSTORE_VERSION=v4.11.1 \
  -t nextcloud-appstore:ubuntu .
```
# Run – assuming PostgreSQL is outside and config mounted into /srv/config

```
docker run -d \
  --name appstore \
  -p 8000:8000 \
  -v /srv/appstore-config:/srv/config \
  -v /srv/appstore-static:/srv/static \
  -v /srv/appstore-media:/srv/media \
  -v /srv/appstore-logs:/srv/logs \
  nextcloud-appstore:ubuntu

```