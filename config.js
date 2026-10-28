// قاعدة البيانات المشتركة لسند (Supabase).
// اتركهما فارغين ليعمل الموقع بالأمثلة على الجهاز فقط.
// المفتاح هنا هو المفتاح العام (Publishable)، وهو آمن في الموقع. لا تضع secret أو service_role أبدًا.
window.SANAD_CONFIG = {
  url: "https://bdbiznxphhxbidnasavc.supabase.co",
  key: "sb_publishable_XxCjHNbXvVnG6BogY60NHg_sOGxTCki",
  // المفتاح العام لإشعارات الجوال (Web Push)، وهو آمن في الموقع. المفتاح الخاص في دالة sanad-push فقط.
  pushKey: "BO9UXMlz99gjquXLsxij3mw_bds9ML9p-nrVVb0Hmhp32Farba10pfYdP_OZdBMwU_T4-rXGqQyIsUaLbm6d5AA",
};
