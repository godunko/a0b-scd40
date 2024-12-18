--
--  Copyright (C) 2024, Vadim Godunko <vgodunko@gmail.com>
--
--  SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
--

pragma Restrictions (No_Elaboration_Code);

pragma Ada_2022;

with A0B.Callbacks.Generic_Non_Dispatching;
with A0B.Time.Constants;

package body A0B.I2C.SCD40 is

   procedure On_Delay (Self : in out SCD40_Driver'Class);

   package On_Delay_Callbacks is
     new A0B.Callbacks.Generic_Non_Dispatching (SCD40_Driver, On_Delay);

   procedure Reset_State (Self : in out SCD40_Driver'Class);
   --  Resets state of the driver.

   procedure Fill_Command_Buffer
     (Self    : in out SCD40_Driver'Class;
      Command : SCD40_Command);
   --  Fill command buffer and link it to first entry of write buffer
   --  descriptor.

   -------------------------
   -- Fill_Command_Buffer --
   -------------------------

   procedure Fill_Command_Buffer
     (Self    : in out SCD40_Driver'Class;
      Command : SCD40_Command) is
   begin
      Self.Command_Buffer (0) :=
        A0B.Types.Unsigned_8
          (A0B.Types.Shift_Right (A0B.Types.Unsigned_32 (Command), 8));
      Self.Command_Buffer (1) :=
        A0B.Types.Unsigned_8 (Command and 16#00FF#);

      Self.Write_Buffers (0).Address :=
        Self.Command_Buffer (Self.Command_Buffer'First)'Address;
      Self.Write_Buffers (0).Size    := Self.Command_Buffer'Length;
   end Fill_Command_Buffer;

   --------------
   -- On_Delay --
   --------------

   procedure On_Delay (Self : in out SCD40_Driver'Class) is
      Success : Boolean := True;

   begin
      Self.Controller.Read
        (Device  => Self'Unchecked_Access,
         Buffers => Self.Read_Buffers,
         Stop    => True,
         Success => Success);
   end On_Delay;

   ------------------------------
   -- On_Transaction_Completed --
   ------------------------------

   overriding procedure On_Transaction_Completed
     (Self : in out SCD40_Driver)
   is
      On_Completed : constant A0B.Callbacks.Callback := Self.On_Completed;

   begin
      --  Cleanup driver's state

      Self.Reset_State;

      --  Notify application

      A0B.Callbacks.Emit (On_Completed);
   end On_Transaction_Completed;

   ---------------------------
   -- On_Transfer_Completed --
   ---------------------------

   overriding procedure On_Transfer_Completed (Self : in out SCD40_Driver) is
      use type A0B.Types.Unsigned_32;

      Success : Boolean := True;

   begin
      case Self.State is
         when Initial =>
            raise Program_Error;

         when Command =>
            pragma Assert (Self.Write_Buffers (0).Size = 2);

            if Self.Write_Buffers (0).State = A0B.Success
              and then Self.Write_Buffers (0).Transferred = 2
              and then Self.Write_Buffers (0).Acknowledged
            then
               --  Command transmission has been completed successfully,
               --  and has been acknowledged by the device.

               Self.Transaction.State := A0B.Success;
               --  Only command have to been send, operation completed.

            else
               Self.Transaction.State := A0B.Failure;
               --  Only command have to been send, operation completed.
            end if;

         when Command_Read =>
            pragma Assert (Self.Write_Buffers (0).Size = 2);

            if Self.Write_Buffers (0).State = A0B.Success
              and then Self.Write_Buffers (0).Transferred = 2
              and then Self.Write_Buffers (0).Acknowledged
            then
               --  Command transmission has been completed successfully,
               --  and has been acknowledged by the device. Delay for given
               --  interval before start to read data from the sensor.

               Self.State := Read;

               A0B.Timer.Enqueue
                 (Self.Timeout,
                  On_Delay_Callbacks.Create_Callback (Self),
                  Self.Delay_Interval);

            else
               --  Command transmission has been failed or device address
               --  has not been acknowledged, set failure state and complete
               --  transaction.

               Self.Transaction.State := A0B.Failure;

               Self.Controller.Stop (Self'Unchecked_Access, Success);

               if not Success then
                  raise Program_Error;
               end if;
            end if;

         when Write =>
            if Self.Write_Buffers (0).State /= A0B.Success
              or else Self.Write_Buffers (1).State /= A0B.Success
            then
               raise Program_Error;
            end if;

            if not Self.Write_Buffers (0).Acknowledged
              or else not Self.Write_Buffers (1).Acknowledged
            then
               raise Program_Error;
            end if;

            --  XXX

            Self.Transaction.Written_Octets :=
              Self.Write_Buffers (1).Transferred;
            Self.Transaction.State          := Self.Write_Buffers (1).State;

         when Write_Read =>
            if Self.Write_Buffers (0).State /= A0B.Success
              or else Self.Write_Buffers (1).State /= A0B.Success
            then
               raise Program_Error;
            end if;

            if not Self.Write_Buffers (0).Acknowledged
              or else not Self.Write_Buffers (1).Acknowledged
            then
               raise Program_Error;
            end if;

            --  XXX

            Self.Transaction.Written_Octets :=
              Self.Write_Buffers (1).Transferred;
            Self.Transaction.State          := Self.Write_Buffers (1).State;
            Self.State                      := Read;

            A0B.Timer.Enqueue
              (Self.Timeout,
               On_Delay_Callbacks.Create_Callback (Self),
               Self.Delay_Interval);

         when Read =>
            if Self.Read_Buffers (0).State /= A0B.Success then
               raise Program_Error;
            end if;

            if not Self.Read_Buffers (0).Acknowledged then
               raise Program_Error;
            end if;

            Self.Transaction.Read_Octets := Self.Read_Buffers (0).Transferred;
            Self.Transaction.State       := Self.Read_Buffers (0).State;

         --  when Write_Read =>
         --     --  Write operation of the single octet of the register address.
         --
         --     pragma Assert (Self.Write_Buffers (0).Size = 1);
         --
         --     if Self.Write_Buffers (0).State = A0B.Success
         --       and then Self.Write_Buffers (0).Transferred = 1
         --       and then Self.Write_Buffers (0).Acknowledged
         --     then
         --        --  Write operation has been completed successfully, register
         --        --  address has been acknowledged by the device.
         --
         --        Self.State := Read;
         --
         --        Self.Controller.Read
         --          (Device  => Self'Unchecked_Access,
         --           Buffers => Self.Read_Buffers,
         --           Stop    => True,
         --           Success => Success);
         --
         --     else
         --        --  Write operation has been failed, set failure state and
         --        --  complete transaction.
         --
         --        Self.Transaction.State := A0B.Failure;
         --
         --        Self.Controller.Stop (Self'Unchecked_Access, Success);
         --     end if;
      end case;
   end On_Transfer_Completed;

   ----------
   -- Read --
   ----------

   procedure Read
     (Self           : in out SCD40_Driver'Class;
      Command        : SCD40_Command;
      Response       : out A0B.Types.Arrays.Unsigned_8_Array;
      Delay_Interval : A0B.Time.Time_Span;
      Status         : aliased out Transaction_Status;
      On_Completed   : A0B.Callbacks.Callback;
      Success        : in out Boolean) is
   begin
      if not Success or Self.State /= Initial then
         Success := False;

         return;
      end if;

      Self.Controller.Start (Self'Unchecked_Access, Success);

      if not Success then
         return;
      end if;

      Self.State           := Command_Read;
      Self.On_Completed    := On_Completed;
      Self.Delay_Interval  := Delay_Interval;
      Self.Transaction     := Status'Unchecked_Access;
      Self.Transaction.all := (0, 0, Active);

      Self.Fill_Command_Buffer (Command);

      Self.Read_Buffers (0).Address := Response (Response'First)'Address;
      Self.Read_Buffers (0).Size    := Response'Length;

      Self.Controller.Write
        (Device  => Self'Unchecked_Access,
         Buffers => Self.Write_Buffers (0 .. 0),
         Stop    => False,
         Success => Success);

      if not Success then
         Self.Transaction.State := Failure;
         Self.Reset_State;
      end if;
   end Read;

   -----------------
   -- Reset_State --
   -----------------

   procedure Reset_State (Self : in out SCD40_Driver'Class) is
   begin
      Self.State          := Initial;
      Self.Delay_Interval := A0B.Time.Constants.Time_Span_Zero;
      A0B.Callbacks.Unset (Self.On_Completed);
      Self.Transaction    := null;
      Self.Write_Buffers  :=
        [others => (System.Null_Address, 0, 0, Active, False)];
      Self.Read_Buffers   :=
        [others => (System.Null_Address, 0, 0, Active, False)];
   end Reset_State;

   ------------------
   -- Send_Command --
   ------------------

   procedure Send_Command
     (Self         : in out SCD40_Driver'Class;
      Command      : SCD40_Command;
      Status       : aliased out Transaction_Status;
      On_Completed : A0B.Callbacks.Callback;
      Success      : in out Boolean) is
   begin
      if not Success or Self.State /= Initial then
         Success := False;

         return;
      end if;

      Self.Controller.Start (Self'Unchecked_Access, Success);

      if not Success then
         return;
      end if;

      Self.State           := SCD40.Command;
      Self.On_Completed    := On_Completed;
      Self.Transaction     := Status'Unchecked_Access;
      Self.Transaction.all := (0, 0, Active);

      Self.Fill_Command_Buffer (Command);

      Self.Controller.Write
        (Device  => Self'Unchecked_Access,
         Buffers => Self.Write_Buffers (0 .. 0),
         Stop    => True,
         Success => Success);

      if not Success then
         Self.Transaction.State := Failure;
         Self.Reset_State;
      end if;
   end Send_Command;

   -----------------------------------
   -- Send_Command_And_Fetch_Result --
   -----------------------------------

   procedure Send_Command_And_Fetch_Result
     (Self           : in out SCD40_Driver'Class;
      Command        : SCD40_Command;
      Input          : A0B.Types.Arrays.Unsigned_8_Array;
      Delay_Interval : A0B.Time.Time_Span;
      Response       : out A0B.Types.Arrays.Unsigned_8_Array;
      Status         : aliased out Transaction_Status;
      On_Completed   : A0B.Callbacks.Callback;
      Success        : in out Boolean) is
   begin
      if not Success or Self.State /= Initial then
         Success := False;

         return;
      end if;

      Self.Controller.Start (Self'Unchecked_Access, Success);

      if not Success then
         return;
      end if;

      Self.State           := Write_Read;
      Self.On_Completed    := On_Completed;
      Self.Delay_Interval  := Delay_Interval;
      Self.Transaction     := Status'Unchecked_Access;
      Self.Transaction.all := (0, 0, Active);

      Self.Fill_Command_Buffer (Command);

      Self.Write_Buffers (1).Address := Input (Input'First)'Address;
      Self.Write_Buffers (1).Size    := Input'Length;
      Self.Read_Buffers (0).Address  := Response (Response'First)'Address;
      Self.Read_Buffers (0).Size     := Response'Length;

      Self.Controller.Write
        (Device  => Self'Unchecked_Access,
         Buffers => Self.Write_Buffers (0 .. 1),
         Stop    => False,
         Success => Success);

      if not Success then
         Self.Transaction.State := Failure;
         Self.Reset_State;
      end if;
   end Send_Command_And_Fetch_Result;

   -----------
   -- Write --
   -----------

   procedure Write
     (Self         : in out SCD40_Driver'Class;
      Command      : SCD40_Command;
      Input        : A0B.Types.Arrays.Unsigned_8_Array;
      Status       : aliased out Transaction_Status;
      On_Completed : A0B.Callbacks.Callback;
      Success      : in out Boolean) is
   begin
      if not Success or Self.State /= Initial then
         Success := False;

         return;
      end if;

      Self.Controller.Start (Self'Unchecked_Access, Success);

      if not Success then
         return;
      end if;

      Self.State           := Write;
      Self.On_Completed    := On_Completed;
      Self.Transaction     := Status'Unchecked_Access;
      Self.Transaction.all := (0, 0, Active);

      Self.Fill_Command_Buffer (Command);

      Self.Write_Buffers (1).Address := Input (Input'First)'Address;
      Self.Write_Buffers (1).Size    := Input'Length;

      Self.Controller.Write
        (Device  => Self'Unchecked_Access,
         Buffers => Self.Write_Buffers (0 .. 1),
         Stop    => True,
         Success => Success);

      if not Success then
         Self.Transaction.State := Failure;
         Self.Reset_State;
      end if;
   end Write;

end A0B.I2C.SCD40;
