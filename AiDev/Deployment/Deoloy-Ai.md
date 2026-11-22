# راهنمای Pipeline: Deoloy-Ai

## هدف

این Pipeline نسخه اصلی موتور هوش مصنوعی را از شاخه `master` می‌سازد، بسته استقرار قابل استفاده برای نصب یا به‌روزرسانی محیط را تولید می‌کند و سپس آن را روی مسیر اصلی AI در سرور Deployment اجرا می‌کند. پس از استقرار سرویس‌ها، مستندات ZagrosHelp نیز منتشر و RAG همگام‌سازی می‌شود.

## جریان کلی عملیات

1. **Build نسخه انتشار**
   - اجرای `Build-Ai-Template.yml` با شاخه ثابت `master`.
   - دریافت کد Repository با نام `AiDev` از شاخه `master`.
   - ساخت Imageهای Docker مربوط به سرویس‌های AI شامل AI Worker، Message Bus، Referral، Synchronization و Control Panel.

2. **تولید Deployment Pack**
   - با فعال بودن گزینه `generatePack`، یک بسته نسخه‌دار بر اساس تاریخ Build تولید می‌شود.
   - بسته شامل اسکریپت نصب مشتری، فایل‌های Docker Compose، فایل‌های نمونه تنظیمات و پیکربندی سرویس‌ها و فایل‌های اولیه موردنیاز Volumeها است.
   - Image مربوط به بسته و Imageهای سرویس‌ها با Tag نسخه و `latest` در Registry منتشر می‌شوند.
   - اسکریپت Bootstrap نیز در مسیر اشتراکی مورد استفاده فرآیند نصب قرار می‌گیرد.

3. **استقرار روی سرور Deployment**
   - Template مشترک `Deploy-AI-Template.yml` اجرا می‌شود.
   - اسکریپت Bootstrap از مسیر اشتراکی نصب دریافت و اجرا می‌شود.
   - Bootstrap بسته انتشار را از Registry دریافت و محتویات آن را در مسیر Deployment استخراج می‌کند.
   - سپس اسکریپت اصلی استقرار اجرا می‌شود تا فایل‌های Runtime، تنظیمات، Volumeها و شبکه موردنیاز آماده و Imageهای سرویس‌ها دریافت شوند.
   - سرویس‌های تعریف‌شده در فایل‌های Docker Compose راه‌اندازی می‌شوند.

4. **انتشار مستندات و همگام‌سازی RAG**
   - Repository مستندات ZagrosHelp از شاخه `master` دریافت می‌شود.
   - مستندات به Volume مربوط به RAG در محیط AI منتقل می‌شوند؛ پوشه‌های `knowledgeBase` در این مرحله مستثنا هستند.
   - فرآیند همگام‌سازی RAG از طریق API سرویس AI Worker اجرا می‌شود.

## مسیرهای اصلی استقرار

| عنوان | مسیر |
|---|---|
| مسیر اصلی AI | `/opt/chargoon/ai` |
| فایل‌ها و اسکریپت‌های استقرار | `/opt/chargoon/ai-deploy` |
| مسیر مشترک بسته نصب | `/mnt/appcs-didgahinstallation/AI-Installation` |

## اجزای اصلی

| جزء | مسئولیت |
|---|---|
| `Build-Ai-Template.yml` | دریافت کد، ساخت Imageها و تولید Deployment Pack |
| `Deploy-AI-Template.yml` | اجرای فرآیند استقرار روی سرور |
| `deploy-ai-bootstrap.sh` | دریافت و استخراج بسته و فراخوانی اسکریپت اصلی |
| `deploy-ai-for-customer.sh` | آماده‌سازی محیط، Imageها و اجرای سرویس‌های AI |
| `deploy-zagros-help.yml` | انتشار مستندات و همگام‌سازی RAG |

## خروجی نهایی

نسخه `master` موتور AI روی مسیر اصلی محیط Deployment نصب یا به‌روزرسانی می‌شود؛ Imageها و Deployment Pack نسخه‌دار در Registry قرار می‌گیرند و مستندات RAG نیز به‌روز می‌شوند.

## تفاوت با Build-Ai

Pipelineِ `Build-Ai` برای محیط Stage و بر اساس شاخه جاری اجرا می‌شود؛ اما این Pipeline همیشه از `master` استفاده می‌کند، Deployment Pack می‌سازد و روی محیط Deployment اصلی استقرار انجام می‌دهد.
