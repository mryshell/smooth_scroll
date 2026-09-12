#!/bin/bash

# ۱. ساخت پوشه مخفی و ورود به آن
mkdir -p .smooth_scroll
cd .smooth_scroll

# ۲. ایجاد فایل smoothscroll.cpp
cat << 'EOF' > smoothscroll.cpp
#include <iostream>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cmath>
#include <chrono>
#include <thread>
#include <cerrno>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <linux/uinput.h>

#ifndef REL_WHEEL_HI_RES
#define REL_WHEEL_HI_RES 0x0b
#endif

int setup_uinput() {
    int uifd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (uifd < 0) return -1;

    ioctl(uifd, UI_SET_EVBIT, EV_REL);
    ioctl(uifd, UI_SET_RELBIT, REL_X);
    ioctl(uifd, UI_SET_RELBIT, REL_Y);
    ioctl(uifd, UI_SET_RELBIT, REL_WHEEL);
    ioctl(uifd, UI_SET_RELBIT, REL_WHEEL_HI_RES);

    ioctl(uifd, UI_SET_EVBIT, EV_KEY);
    ioctl(uifd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(uifd, UI_SET_KEYBIT, BTN_RIGHT);
    ioctl(uifd, UI_SET_KEYBIT, BTN_MIDDLE);

    struct uinput_user_dev uidev;
    std::memset(&uidev, 0, sizeof(uidev));
    std::strncpy(uidev.name, "HiRes Smooth Mouse", UINPUT_MAX_NAME_SIZE);
    uidev.id.bustype = BUS_USB;
    uidev.id.vendor  = 0x1234;
    uidev.id.product = 0x5678;
    uidev.id.version = 1;

    write(uifd, &uidev, sizeof(uidev));
    ioctl(uifd, UI_DEV_CREATE);
    return uifd;
}

void emit_event(int uifd, int type, int code, int val) {
    struct input_event ie;
    std::memset(&ie, 0, sizeof(ie));
    ie.type = type;
    ie.code = code;
    ie.value = val;
    write(uifd, &ie, sizeof(ie));

    ie.type = EV_SYN;
    ie.code = SYN_REPORT;
    ie.value = 0;
    write(uifd, &ie, sizeof(ie));
}

int main() {
    int real_fd = -1;

    // اسکن خودکار بین event0 تا event20 برای پیدا کردن موس واقعی
    for (int i = 0; i < 20; ++i) {
        std::string path = "/dev/input/event" + std::to_string(i);
        int fd = open(path.c_str(), O_RDONLY | O_NONBLOCK);
        if (fd >= 0) {
            char name[256] = "Unknown";
            ioctl(fd, EVIOCGNAME(sizeof(name)), name);
            
            // جلوگیری از قفل کردن موس مجازی ساخته شده توسط برنامه
            if (std::string(name).find("HiRes Smooth Mouse") == std::string::npos) {
                unsigned long relbit = 0;
                ioctl(fd, EVIOCGBIT(EV_REL, sizeof(relbit)), &relbit);
                
                // چک کردن قابلیت اسکرول (REL_WHEEL)
                if (relbit & (1 << REL_WHEEL)) {
                    real_fd = fd;
                    std::cout << "Mous peyda shod rooye: " << path << " (" << name << ")" << std::endl;
                    break;
                }
            }
            close(fd);
        }
    }

    if (real_fd < 0) {
        std::cerr << "Khata: Hich moosi ba ghabiliat scroll peyda nashod!" << std::endl;
        return 1;
    }

    int uifd = setup_uinput();
    if (uifd < 0) {
        std::cerr << "Khata dar sakht uinput!" << std::endl;
        close(real_fd);
        return 1;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    
    if (ioctl(real_fd, EVIOCGRAB, 1) < 0) {
        std::cerr << "Khata dar EVIOCGRAB!" << std::endl;
        ioctl(uifd, UI_DEV_DESTROY);
        close(uifd);
        close(real_fd);
        return 1;
    }

    double velocity = 0.0;
    double accumulator = 0.0;
    const double IMPULSE = 2.0;
    const double FRICTION = 0.99;

    struct input_event ev;
    bool running = true;

    while (running) {
        while (true) {
            ssize_t bytes = read(real_fd, &ev, sizeof(ev));
            if (bytes == sizeof(ev)) {
                if (ev.type == EV_REL) {
                    if (ev.code == REL_WHEEL || ev.code == REL_WHEEL_HI_RES) {
                        if (ev.code == REL_WHEEL) {
                            velocity += ev.value * IMPULSE;
                        }
                    } else {
                        emit_event(uifd, EV_REL, ev.code, ev.value);
                    }
                } else if (ev.type == EV_KEY) {
                    emit_event(uifd, EV_KEY, ev.code, ev.value);
                }
            } else if (bytes < 0) {
                // اگر خطای خواندن به خاطر خالی بودن بافر نباشه، یعنی موس قطع شده
                if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    std::cerr << "Mous ghat shod! Khrooj baraye restart..." << std::endl;
                    running = false;
                }
                break;
            } else {
                break;
            }
        }

        if (std::abs(velocity) > 0.1) {
            accumulator += velocity;

            int step = static_cast<int>(accumulator);
            if (step != 0) {
                emit_event(uifd, EV_REL, REL_WHEEL_HI_RES, step);
                accumulator -= step;
            }

            velocity *= FRICTION;
        } else {
            velocity = 0.0;
            accumulator = 0.0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }

    ioctl(real_fd, EVIOCGRAB, 0);
    ioctl(uifd, UI_DEV_DESTROY);
    close(uifd);
    close(real_fd);

    return 1;
}
EOF

# ۳. نصب ابزارها و کامپایل کد
echo "[+] Installing build-essential and g++..."
sudo apt update && sudo apt install -y build-essential g++

echo "[+] Compiling smoothscroll.cpp..."
g++ smoothscroll.cpp -o smoothscroll -pthread

# ۴. گرفتن مسیر دقیق پوشه مخفی برای سرویس
EXEC_PATH="$(pwd)/smoothscroll"
WORK_DIR="$(pwd)"

# ۵. ساخت و تنظیم سرویس systemd برای اجرای اتوماتیک
echo "[+] Setting up systemd service..."
sudo bash -c "cat << EOF > /etc/systemd/system/smoothscroll.service
[Unit]
Description=HiRes Smooth Scroll Service
After=multi-user.target

[Service]
Type=simple
ExecStart=${EXEC_PATH}
WorkingDirectory=${WORK_DIR}
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF"

# ۶. بارگذاری، فعال‌سازی و اجرای سرویس
sudo systemctl daemon-reload
sudo systemctl enable smoothscroll.service
sudo systemctl restart smoothscroll.service

echo "=========================================="
echo "Done! Hidden folder '.smooth_scroll' created."
echo "Smooth Scroll is installed and running as a service."
echo "Status check: sudo systemctl status smoothscroll.service"
echo "=========================================="
