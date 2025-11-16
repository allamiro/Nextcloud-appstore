
From the repo root copy the environment files to ```.env``` then run

```
docker compose build
docker compose up -d
```


Then create the admin user and set up GitHub social login inside the app container:


```
docker compose exec app bash

# Inside container:
python manage.py createsuperuser --username admin --email admin@example.com
python manage.py verifyemail --username admin --email admin@example.com

# (After you have GitHub client/secret)
python manage.py setupsocial \
  --github-client-id "CLIENT_ID" \
  --github-secret "SECRET" \
  --domain apps.example.com

```
