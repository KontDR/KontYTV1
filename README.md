# KontYT — build repo (0.13.40 / build63 / R57)

Bu depo **sadece derleme** içindir: iki dosya + kaynak snapshot'ı.
İçinde uygulama kaynağı yok; kaynak, `scripts/restore_kontyt.py` çalıştığında **geçici derleme ortamında** açılır.

## 1) Repo aç
GitHub › **New repository** → isim: `KontYT-build` → **Public** (private'da macOS dakikaları ücretli) →
*Add a README file* işaretini **kaldır** → **Create repository**.

## 2) Dosyaları yükle
Bu paketteki klasör yapısını olduğu gibi sürükle-bırak (GitHub web'de klasör sürüklemek çalışır):

```
.github/workflows/kontyt-build.yml
scripts/restore_kontyt.py
codemagic.yaml        (isteğe bağlı — Codemagic yolu)
```

Commit mesajı: `KontYT R57` → **Commit changes**.

## 3) Derleme kendiliğinden başlar
Her `push` (ana dala) iş akışını otomatik çalıştırır — dosyaları yüklemek yeterli, elle başlatmaya gerek yok.
İzlemek için: **Actions › KontYT Guncel › KontYT 0.13.40 build63 R57**.
Elle başlatmak istersen: Actions › KontYT Guncel › **Run workflow** › variant: `with-share` › Run.

Adımlar (kırmızı olursa adı nerede durduğunu söyler):
```
Restore verified source snapshot → kaynak açılır (207 dosya)
0/5 Ortam ve yuklenen dosyalar   → macOS, python3, iki dosyanın sha256'sı
1/5 Python bagimliliklari
2/5 Birim testleri               → 132 test
3/5 Surum paketi butunlugu
4/5 Kaynak ve varlik denetimi
Run simulator unit tests         → derleme + XCTest
Package for AltStore signing     → KontYT-sideload.ipa
```
Süre: ~10 dakika (ilk run'da XcodeGen kurulumu biraz uzun).

## 4) IPA'yı indir
Run sayfasının altındaki **Artifacts**:
- `KontYT-AltStore` → `KontYT-sideload.ipa` (imzasız; AltStore/SideStore ile kurulur)
- `KontYT-BuildDiagnostics` → derleme/test logları
- `KontYT-TestResults` → `.xcresult`

## Alternatif: Codemagic
Depo private kalsın istiyorsan `codemagic.yaml` da paket içinde: codemagic.io › Add application ›
bu depoyu seç › **KontYT imzasiz IPA** (ayda 500 macOS M2 dakikası ücretsiz).

## Not
- IPA imzasızdır; imzalama ve kurulum AltStore/SideStore tarafında olur.
- `scripts/restore_kontyt.py` 2.6 MB'tır, normaldir (snapshot base64 olarak içinde).
- Derleme başarılı olursa aynı dosyalar her zaman aynı sürümü üretir: **marketing 0.13.40, build 63**.

## Yenilikler (R57)
- **Canlı efekt temiz ses:** Dalga şekillendirici (`tanh`) kaldırıldı, yerine zarflı sınırlayıcı
  (atak 1 ms, bırakma ~90 ms, tavan 0,98). EQ yükseltmesi için baş mesafesi geri alınıyor, bant
  kazançları bloğa yayılarak yumuşatılıyor (çıt sesi gitti).
- **12 bant ekolayzer:** 32 Hz – 12 kHz; uçlar raf, ara bantlar Q 1,1 tepe filtresi; −12…+12 dB.
  Yeni hazır ayarlar: Podcast, Tiz artır. Eski kısa bant listesi sıfırla tamamlanır.
- **İki modlu sözler:** Alışılan **Liste** görünümü duruyor; yeni **Karaoke** modunda kelimeler
  çaldıkça nane rengine döner, geçmiş satırlar kararır. Oynatıcıdaki söz şeridi de aynı modu izler.
- **Apple Music'e iki dürüst yol:** Kısayollar tarifi (kopyalanabilir, 4 adım) + Dosyalar'a kaydet.
  iOS hiçbir uygulamaya Music kütüphanesine yazma izni vermez; sebep uygulamada yazılı.
- **Ses düzeyi eşitleme:** Üç noktadan örneklenen ortalama seviyeye göre çalma sırasında düzeltme
  (−12…+12 dB, tepe tavanlı). Dosya değişmez, sıkıştırma yok.
- **Akıllı çalma listeleri:** Kayıtlı filtreler (tür, söz, çalma sayısı, eklenme tarihi, süre,
  favori). Kural kayıt değildir; uygun yeni parça kendiliğinden girer.
- **Uyku zamanlayıcısı:** 90 ve 120 dakika + **"Parça sonunda dur"** (sıradaki başlamaz).
- **A–B işaretleri isimlendiriliyor:** "nakarat", "solo" gibi adlarla kaydedilir; menüden açılınca
  o bölüm döngüde çalar.
- **Çalma istatistikleri:** Toplam çalma, dinlenen süre, en çok çalınanlar. Duraklatılan süre
  sayılmaz; silinen dosyanın geçmişi de gider.
- **Wi-Fi aktarım kuyruğu:** Bilgisayardan gelen her dosya için satır + ilerleme çubuğu.
- **Yedekten seçici geri yükleme:** Dosya listesi, arama, tek tek seçim; istersen yalnızca
  listeler/favoriler/yer imleri geri gelir.
- **Toplu başlık/sanatçı ayırma:** "Sanatçı - Başlık" kalıbı + parantezli ekler temizlenir; önce
  önizleme, sonra uygulama. Sanatçı bulunamayan satır değişmez.
- **Paylaşım uzantısında Müzik / Video sorusu:** Uygulama içinde "sorma" desen de dışarıdan gelen
  bağlantıda soru sorulur (Ayarlar'dan kapatılabilir).
- **Bağlantı alma düzeltildi:** Dışarıdan gelen bağlantı artık keşfi kendiliğinden açıyor (3. sekme
  tarayıcıydı, bağlantı orada bekliyordu); görülmemiş paylaşımlar silinmiyor; kopyalanan bağlantı
  **otomatik kuyruğa giriyor** (Ayarlar: Otomatik / Onay kartı / Kapalı); sayfada açık videonun
  yanında tek dokunuşluk indir düğmesi var.
