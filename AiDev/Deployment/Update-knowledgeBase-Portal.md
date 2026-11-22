# راهنمای Pipeline: Update-knowledgeBase-Portal

## هدف

این Pipeline برای به‌روزرسانی محتوای Knowledge Base در محیط AI Portal طراحی شده است. برخلاف Pipelineهای Build و Deploy، در این فرآیند Image جدیدی ساخته نمی‌شود و سرویس‌های AI نیز مجدداً Deploy نمی‌شوند؛ تمرکز آن فقط روی انتقال محتوای منتخب مستندات و اجرای همگام‌سازی RAG است.

## جریان کلی عملیات

1. **دریافت Repository مستندات**
   - Template مربوط به Knowledge Base، شاخه `master` از Repository با نام `ZagrosHelp` را دریافت یا به‌روزرسانی می‌کند.
   - محتوای مستندات از مسیر `docs` خوانده می‌شود.

2. **انتخاب و انتقال محتوا**
   - تمام پوشه‌هایی که نام آن‌ها `knowledgeBase` است، با حفظ ساختار مسیرشان به محیط AI Portal منتقل می‌شوند.
   - علاوه بر آن، پوشه `docs/Automation/مکاتبات` نیز به‌صورت مستقل منتقل می‌شود.
   - مقصد محتوا، مسیر مستندات در Volume مربوط به RAG است.

3. **اجرای همگام‌سازی RAG**
   - پس از انتقال محتوا، درخواست اجرای فرآیند همگام‌سازی و Embedding به API سرویس AI ارسال می‌شود.
   - در ادامه اطلاعات Volume و منابع (Sources) ثبت‌شده در RAG از API دریافت و در خروجی Pipeline نمایش داده می‌شود.

## مسیرهای اصلی

| عنوان | مسیر |
|---|---|
| Repository مستندات روی سرور | زیر مسیر `/opt/chargoon/asa-portal/ZagrosHelp-git` |
| مسیر مقصد مستندات RAG | `/opt/chargoon/asa-portal/volumes/ai-worker/rag_ingest/docs` |
| API سرویس RAG | `http://localhost:8110` |

## اجزای اصلی

| جزء | مسئولیت |
|---|---|
| `deploy-knowledgebase-template.yml` | دریافت مستندات، انتخاب پوشه‌های Knowledge Base، انتقال محتوا و اجرای همگام‌سازی RAG |

## خروجی نهایی

محتوای Knowledge Base و مکاتبات Automation در Volume مربوط به RAG در محیط AI Portal به‌روزرسانی می‌شود و فرآیند Sync/Embedding برای در دسترس قرار گرفتن محتوای جدید اجرا می‌شود.

## تفاوت با سایر Pipelineها

این Pipeline یک فرآیند به‌روزرسانی محتوا است، نه فرآیند انتشار نسخه نرم‌افزار:
- Image جدیدی Build یا منتشر نمی‌کند.
- فایل‌های اجرایی و سرویس‌های Docker Compose را Deploy نمی‌کند.
- فقط محتوای منتخب مستندات را منتقل و RAG را همگام‌سازی می‌کند.
