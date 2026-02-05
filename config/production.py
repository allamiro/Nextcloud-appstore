# =============================================================================
# Nextcloud App Store - Production Configuration
# =============================================================================
# This file is mounted into the container at /srv/config/production.py
# Customize for your environment before deployment
# =============================================================================

import os
from nextcloudappstore.settings.base import *

# =============================================================================
# Security Settings
# =============================================================================

# CRITICAL: Generate a unique secret key for production!
# Use: env LC_CTYPE=C tr -dc "a-zA-Z0-9-_\$\?" < /dev/urandom | head -c 64; echo
SECRET_KEY = os.environ.get('SECRET_KEY', 'CHANGE_THIS_IN_PRODUCTION')

# Hosts allowed to connect
ALLOWED_HOSTS = os.environ.get('ALLOWED_HOSTS', 'localhost').split(',')

# Debug mode - MUST be False in production
DEBUG = os.environ.get('DEBUG', 'False').lower() == 'true'

# =============================================================================
# Database Configuration
# =============================================================================

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('DATABASE_NAME', 'nextcloudappstore'),
        'USER': os.environ.get('DATABASE_USER', 'nextcloudappstore'),
        'PASSWORD': os.environ.get('DATABASE_PASSWORD', 'password'),
        'HOST': os.environ.get('DATABASE_HOST', '127.0.0.1'),
        'PORT': os.environ.get('DATABASE_PORT', '5432'),
    }
}

# =============================================================================
# Static and Media Files
# =============================================================================

STATIC_URL = '/static/'
STATIC_ROOT = '/srv/static/'

MEDIA_URL = os.environ.get('MEDIA_URL', '/media/')
MEDIA_ROOT = '/srv/media/'

# =============================================================================
# Email Configuration
# =============================================================================

DEFAULT_FROM_EMAIL = os.environ.get('DEFAULT_FROM_EMAIL', 'appstore@example.com')
EMAIL_HOST = os.environ.get('EMAIL_HOST', 'localhost')
EMAIL_PORT = int(os.environ.get('EMAIL_PORT', '25'))
EMAIL_HOST_USER = os.environ.get('EMAIL_HOST_USER', '')
EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_HOST_PASSWORD', '')
EMAIL_USE_TLS = os.environ.get('EMAIL_USE_TLS', 'False').lower() == 'true'

ADMINS = [
    (os.environ.get('ADMIN_NAME', 'Admin'), os.environ.get('ADMIN_EMAIL', 'admin@example.com'))
]

# =============================================================================
# GitHub API Token (for syncing Nextcloud releases)
# =============================================================================

GITHUB_API_TOKEN = os.environ.get('GITHUB_API_TOKEN', '')

# =============================================================================
# reCAPTCHA Configuration (optional)
# =============================================================================

RECAPTCHA_PUBLIC_KEY = os.environ.get('RECAPTCHA_PUBLIC_KEY', '')
RECAPTCHA_PRIVATE_KEY = os.environ.get('RECAPTCHA_PRIVATE_KEY', '')

# Disable reCAPTCHA if keys not provided
if not RECAPTCHA_PUBLIC_KEY or not RECAPTCHA_PRIVATE_KEY:
    SILENCED_SYSTEM_CHECKS = ['captcha.recaptcha_test_key_error']

# =============================================================================
# Discourse Integration (optional)
# =============================================================================

DISCOURSE_URL = os.environ.get('DISCOURSE_URL', 'https://help.nextcloud.com')
DISCOURSE_USER = os.environ.get('DISCOURSE_USER', '')
DISCOURSE_TOKEN = os.environ.get('DISCOURSE_TOKEN', '')

# =============================================================================
# Logging Configuration
# =============================================================================

LOG_FILE = os.environ.get('LOG_FILE', '/srv/logs/appstore.log')

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {process:d} {thread:d} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'file': {
            'level': 'INFO',
            'class': 'logging.FileHandler',
            'filename': LOG_FILE,
            'formatter': 'verbose',
        },
        'console': {
            'level': 'INFO',
            'class': 'logging.StreamHandler',
            'formatter': 'verbose',
        },
    },
    'root': {
        'handlers': ['console', 'file'],
        'level': 'INFO',
    },
}

# =============================================================================
# Security Headers (for production behind proxy)
# =============================================================================

SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
USE_X_FORWARDED_HOST = True
USE_X_FORWARDED_PORT = True

# HTTPS settings (enable when behind SSL terminating proxy)
if os.environ.get('USE_HTTPS', 'True').lower() == 'true':
    SECURE_SSL_REDIRECT = False  # Let nginx handle this
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True

# =============================================================================
# CORS Settings (if needed for API access)
# =============================================================================

CORS_ALLOWED_ORIGINS = os.environ.get('CORS_ALLOWED_ORIGINS', '').split(',') if os.environ.get('CORS_ALLOWED_ORIGINS') else []

# =============================================================================
# Rate Limiting
# =============================================================================

REST_FRAMEWORK = {
    'DEFAULT_THROTTLE_CLASSES': [
        'rest_framework.throttling.AnonRateThrottle',
        'rest_framework.throttling.UserRateThrottle'
    ],
    'DEFAULT_THROTTLE_RATES': {
        'anon': os.environ.get('THROTTLE_ANON', '100/hour'),
        'user': os.environ.get('THROTTLE_USER', '1000/hour'),
        'app_upload': os.environ.get('THROTTLE_APP_UPLOAD', '100/day'),
        'app_register': os.environ.get('THROTTLE_APP_REGISTER', '100/day'),
    }
}
