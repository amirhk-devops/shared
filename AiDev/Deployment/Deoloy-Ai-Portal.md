# راهنمای Pipeline: Deoloy-Ai-Portal

## هدف

این Pipeline نسخه اصلی سرویس‌های AI را از شاخه `master` Build می‌کند، Deployment Pack را تولید می‌کند و آن را برای استقرار محیط AI Portal روی سرور Deployment به کار می‌گیرد.

این Pipeline از فرآیند Build و بسته‌بندی مشترک موتور AI استفاده می‌کند؛ تفاوت اصلی آن با Pipelineِ `Deoloy-Ai` در مسیر مقصد است. در اینجا سرویس‌ها در مسیر مربوط به Portal نصب می‌شوند و نه مسیر اصلی AI.

## جریان کلی عملیات

1. **Build نسخه انتشار**
   - اجرای `Build-Ai-Template.yml` با شاخه `master`.
   - دریافت کد Repository با نام `AiDev` از شاخه `master`.
   - ساخت Imageهای Docker سرویس‌های AI شامل AI Worker، Message Bus، Referral، Synchronization و Control Panel.

2. **تولید و انتشار Deployment Pack**
   - تولید بسته نصب نسخه‌دار شامل فایل‌های Docker Compose، تنظیمات، اسکریپت‌های استقرار و فایل‌های اولیه Volumeها.
   - ساخت Image مربوط به Deployment Pack.
   - انتشار Imageهای سرویس‌ها و بسته نصب با Tag نسخه و `latest` در Registry.

3. **استقرار محیط AI Portal**
   - اجرای Template مشترک `Deploy-AI-Template.yml`.
   - دریافت اسکریپت Bootstrap از مسیر مشترک بسته نصب و اجرای آن.
   - دریافت بسته از Registry و استخراج فایل‌های آن.
   - اجرای فرآیند اصلی استقرار برای آماده‌سازی مسیر Portal، تنظیمات، Volumeها، شبکه و سرویس‌های Docker Compose.

## مسیرهای اصلی استقرار

| عنوان | مسیر |
|---|---|
| مسیر ریشه | `/opt/chargoon` |
| مسیر محیط AI Portal | `/opt/chargoon/asa-portal` |
| مسیر فایل‌ها و اسکریپت‌های استقرار | `/opt/chargoon/asa-portal-ai-deploy` |
| مسیر مشترک بسته نصب | `/mnt/appcs-didgahinstallation/AI-Installation` |

## اجزای اصلی

| جزء | مسئولیت |
|---|---|
| `Build-Ai-Template.yml` | دریافت کد، ساخت Imageها و تولید Deployment Pack |
| `Deploy-AI-Template.yml` | اجرای فرآیند استقرار در مسیر Portal |
| `deploy-ai-bootstrap.sh` | دریافت و استخراج بسته و شروع فرآیند استقرار |
| `deploy-ai-for-customer.sh` | آماده‌سازی محیط و اجرای سرویس‌های AI |

## خروجی نهایی

سرویس‌های AI بر اساس نسخه `master` در مسیر اختصاصی AI Portal مستقر می‌شوند و Imageها و بسته انتشار نیز در Registry در دسترس قرار می‌گیرند.

## تفاوت با Deoloy-Ai

مراحل Build، تولید بسته و روش استقرار در هر دو Pipeline مشترک است. تفاوت اصلی در مسیر مقصد است:
- `Deoloy-Ai`: مسیر `/opt/chargoon/ai`
- `Deoloy-Ai-Portal`: مسیر `/opt/chargoon/asa-portal`

این Pipeline مرحله انتشار ZagrosHelp و همگام‌سازی RAG را که در `Deoloy-Ai` وجود دارد اجرا نمی‌کند.
