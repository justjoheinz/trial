(in-package #:org.shirakumo.fraf.trial.sdl2)

(defvar *sdl2-scancode-map*
  (let ((table (make-hash-table)))
    (loop for (key idx) in
          '((:unknown 0)
            (:a 4)
            (:b 5)
            (:c 6)
            (:d 7)
            (:e 8)
            (:f 9)
            (:g 10)
            (:h 11)
            (:i 12)
            (:j 13)
            (:k 14)
            (:l 15)
            (:m 16)
            (:n 17)
            (:o 18)
            (:p 19)
            (:q 20)
            (:r 21)
            (:s 22)
            (:t 23)
            (:u 24)
            (:v 25)
            (:w 26)
            (:x 27)
            (:y 28)
            (:z 29)
            (:1 30)
            (:2 31)
            (:3 32)
            (:4 33)
            (:5 34)
            (:6 35)
            (:7 36)
            (:8 37)
            (:9 38)
            (:0 39)
            (:enter 40)
            (:escape 41)
            (:backspace 42)
            (:tab 43)
            (:space 44)
            (:minus 45)
            (:equals 46)
            (:left-bracket 47)
            (:right-bracket 48)
            (:backslash 49)
            (:nonus-hash 50)
            (:semicolon 51)
            (:apostrophe 52)
            (:grave-accent 53)
            (:comma 54)
            (:period 55)
            (:slash 56)
            (:caps-lock 57)
            (:f1 58)
            (:f2 59)
            (:f3 60)
            (:f4 61)
            (:f5 62)
            (:f6 63)
            (:f7 64)
            (:f8 65)
            (:f9 66)
            (:f10 67)
            (:f11 68)
            (:f12 69)
            (:print-screen 70)
            (:scroll-lock 71)
            (:pause 72)
            (:insert 73)
            (:home 74)
            (:pageup 75)
            (:delete 76)
            (:end 77)
            (:pagedown 78)
            (:right 79)
            (:left 80)
            (:down 81)
            (:up 82)
            (:num-lock 83)
            (:kp-divide 84)
            (:kp-multiply 85)
            (:kp-subtract 86)
            (:kp-add 87)
            (:kp-enter 88)
            (:kp-1 89)
            (:kp-2 90)
            (:kp-3 91)
            (:kp-4 92)
            (:kp-5 93)
            (:kp-6 94)
            (:kp-7 95)
            (:kp-8 96)
            (:kp-9 97)
            (:kp-0 98)
            (:kp-decimal 99)
            (:kp-equal 103)
            (:f13 104)
            (:f14 105)
            (:f15 106)
            (:f16 107)
            (:f17 108)
            (:f18 109)
            (:f19 110)
            (:f20 111)
            (:f21 112)
            (:f22 113)
            (:f23 114)
            (:f24 115)
            (:left-ctrl 224)
            (:left-shift 225)
            (:left-alt 226)
            (:left-super 227)
            (:right-ctrl 228)
            (:right-shift 229)
            (:right-alt 230)
            (:right-super 231)
            (:menu 257))
          do (setf (gethash idx table) key))
    (let ((array (make-array (1+ (loop for idx being the hash-keys of table
                                       maximize idx))
                             :initial-element :unknown)))
      (loop for idx being the hash-keys of table
            for key being the hash-values of table
            do (setf (aref array idx) key))
      array)))
