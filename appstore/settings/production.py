# settings/production.py (very simplified sketch!)
from .base import *

import os

DEBUG = False

SECRET_KEY = os.environ.get("SECRET_KEY", "change-me")

ALLOWED_HOSTS = ["apps.example.com", "localhost"]

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ.get("POSTGRES_DB", "nextcloudappstore"),
        "USER": os.environ.get("POSTGRES_USER", "nextcloudappstore"),
        "PASSWORD": os.environ.get("POSTGRES_PASSWORD", "changeme"),
        "HOST": os.environ.get("POSTGRES_HOST", "db"),
        "PORT": os.environ.get("POSTGRES_PORT", "5432"),
    }
}

STATIC_ROOT = "/var/www/nextcloud-appstore/static"
MEDIA_ROOT = "/var/www/nextcloud-appstore/media"
