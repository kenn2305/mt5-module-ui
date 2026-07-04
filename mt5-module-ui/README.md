# MT5 Module UI

Rootless tweak cho MetaTrader 5 trên iOS 15–16. Tool lấy trực tiếp các tab và icon đang chạy trong MT5 để dựng giao diện Designer, không dựa vào danh sách tab mẫu.

## Chức năng hiện có

- Clone danh sách controller, title và icon thật của thanh tab MT5.
- Preview thanh tab ngay trong Designer.
- Kéo thả để đổi thứ tự module.
- Bật/tắt module, đổi tên và chọn icon từ Photos.
- Quét icon/nút thật bên trong từng màn hình MT5.
- Kéo trực tiếp để đổi vị trí, pinch để đổi kích thước, thay ảnh hoặc ẩn icon.
- Thêm icon mới từ Photos hoặc thư viện hình Plus/Pencil/Clock/Menu/More/Chart.
- Liên kết icon mới với hành động của nút MT5 gốc.
- Apply trực tiếp bằng cách sắp xếp lại controller gốc của MT5.
- Lưu JSON atomic, giữ bản backup và Reset về layout gốc.
- Tự bỏ qua module không nhận diện được và đưa module mới của MT5 vào cuối danh sách.
- Chỉ inject vào `net.metaquotes.MetaTrader5Terminal`.

## Mở Designer

Sau khi cài tweak và mở MT5, nhấn giữ thanh tab phía dưới khoảng **0,8 giây**.

Designer đang mở trên chính tab/controller thật của phiên MT5 hiện tại. Kéo hàng bằng tay nắm reorder, chạm vào hàng để đổi tên hoặc icon, sau đó nhấn **Apply**.

## Chỉnh icon bên trong từng tab

1. Mở đúng màn hình cần chỉnh, ví dụ **Giá**, **Biểu đồ**, **Giao dịch** hoặc **Lịch sử**.
2. Nhấn giữ thanh tab dưới 0,8 giây để mở Designer.
3. Chọn **Edit icons in current screen**.
4. Tool khoanh các icon/nút tìm thấy ngay trên màn hình thật.
5. Chạm icon để chọn, kéo để đổi vị trí, pinch để đổi kích thước.
6. Dùng **Replace**, **Hide/Delete** hoặc **Add** rồi nhấn **Apply**.

Icon mới mặc định là hình hiển thị. Muốn nó thực hiện một chức năng, chọn icon mới → **Link** → chạm nút MT5 gốc cần sao chép hành động. Editor lưu layout riêng theo class/title của từng màn hình và áp lại khi màn hình xuất hiện.

## Build trên GitHub

Workflow `.github/workflows/mt5-module-ui.yml` chạy trên macOS để có toolchain arm64e phù hợp:

1. Cài GNU Make, ldid và dpkg.
2. Clone Theos và iOS SDKs.
3. Build rootless fat dylib `arm64 + arm64e`.
4. Kiểm tra metadata `.deb` và kiến trúc bằng `lipo`.
5. Upload `.deb` thành GitHub Actions artifact.

Chạy workflow thủ công hoặc tạo tag dạng `mt5-module-ui-v0.1.0` để đồng thời publish APT repo lên GitHub Pages.

## Cài qua Sileo

Sau khi workflow Pages chạy thành công:

1. Bật **Settings → Pages → Source: GitHub Actions** trong repository GitHub.
2. Thêm source `https://<github-user>.github.io/<repository>/` vào Sileo.
3. Tìm `MT5 Module UI` và cài package.
4. Mở lại MT5 rồi nhấn giữ thanh tab.

Package có architecture `iphoneos-arm64`, còn dylib bên trong chứa cả `arm64` và `arm64e`. Deployment target là iOS 15.0 và `control` chặn cài ngoài iOS 15–16.

## Build local trên macOS

```sh
export THEOS="$HOME/theos"
cd mt5-module-ui
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

File cài đặt nằm trong `packages/`.

## Dữ liệu và an toàn

Cấu hình được lưu trong Application Support của sandbox MT5 tại thư mục `MT5ModuleUI`. Runtime giữ lại controller gốc trong bộ nhớ và không hook Buy/Sell, network, tài khoản hoặc xử lý lệnh giao dịch.

Nếu config không hợp lệ hoặc không còn module hiển thị, runtime từ chối Apply. **Reset original MT5 layout** xóa config và khôi phục controller, title và icon đã inventory khi MT5 khởi động.

## Trạng thái kiểm thử

- Đã có validator cấu trúc chạy độc lập bằng Python.
- GitHub workflow chịu trách nhiệm compile/link/package thật vì máy Windows hiện tại không có Xcode/Theos toolchain.
- Cần test trên thiết bị jailbreak iOS 15 và iOS 16 trước khi coi là production-ready, đặc biệt với các build MT5 khác build 5219.
