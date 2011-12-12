with Posix_Shell.Builtins_Printf; use Posix_Shell.Builtins_Printf;
with Posix_Shell.Builtins_Expr; use Posix_Shell.Builtins_Expr;
with Posix_Shell.Builtins.Test; use Posix_Shell.Builtins.Test;
with Posix_Shell.Builtins.Tail; use Posix_Shell.Builtins.Tail;
with Posix_Shell.Builtins.Head; use Posix_Shell.Builtins.Head;
with Posix_Shell.Exec; use Posix_Shell.Exec;
with Posix_Shell.Variables.Output; use Posix_Shell.Variables.Output;
with Posix_Shell.Parser; use Posix_Shell.Parser;
with Posix_Shell.Tree; use Posix_Shell.Tree;
with Posix_Shell.Tree.Evals; use Posix_Shell.Tree.Evals;
with Posix_Shell.Utils; use Posix_Shell.Utils;
with Posix_Shell.Annotated_Strings; use Posix_Shell.Annotated_Strings;
with Posix_Shell.Subst; use Posix_Shell.Subst;
with Posix_Shell.Commands_Preprocessor; use Posix_Shell.Commands_Preprocessor;

with Ada.Strings.Unbounded;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with GNAT.Directory_Operations;

package body Posix_Shell.Builtins is

   type Builtin_Function
     is access function
       (S : Shell_State_Access; Args : String_List) return Integer;
   --  The signature of a function implementing a given builtin.

   package Builtin_Maps is
     new Ada.Containers.Indefinite_Hashed_Maps
       (String,
        Builtin_Function,
        Hash => Ada.Strings.Hash,
        Equivalent_Keys => "=");
   use Builtin_Maps;

   Builtin_Map : Map;
   --  A map of all builtins.

   function Change_Dir
     (S : Shell_State_Access;
      Dir_Name : String;
      Verbose : Boolean := False)
     return Integer;
   --  Change the directory to Dir_Name and return 0 if successful.
   --  This function also maintains the PWD and OLDPWD variables.
   --  If Verbose is True and the directory change was successful,
   --  then print on standard output the name of the new directory.
   --
   --  This function does nothing and returns zero if Dir_Name is
   --  the empty string.

   function Return_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;
   --  Implement the "return" builtin.

   function Shift_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;
   --  Implement the "shift" builtin.

   function Exec_Builtin
     (S : Shell_State_Access; Args : String_List)
      return Integer;
   --  The exec utility shall open, close, and/or copy file descriptors as
   --  specified by any redirections as part of the command.
   --  If exec is specified with command, it shall replace the shell with
   --  command without creating a new process. If arguments are specified, they
   --  shall be arguments to command. Redirection affects the current shell
   --  execution environment. (part of POSIX.1-2008).
   --
   --  Implementation Notes: a special case in Posix_Shell_Tree.Evals.Eval_Cmd
   --  is taking care of exec redirections. Furthermore in case a command is
   --  specified to exec a process will be spawned as there is no notion of
   --  fork/exec on Windows systems.

   function Change_Dir_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Echo_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Eval_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function REcho_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Source_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function True_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function False_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Export_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Set_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Unsetenv_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Limit_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Exit_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Wc_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Continue_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Break_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Read_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Cat_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Pwd_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Unset_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   function Rm_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer;

   -------------------
   -- Break_Builtin --
   -------------------

   function Break_Builtin
     (S : Shell_State_Access; Args : String_List)
      return Integer
   is
      Break_Number : Integer;
      Is_Valid : Boolean;
      Current_Loop_Level : constant Natural := Get_Loop_Scope_Level (S.all);
   begin

      if Current_Loop_Level = 0 then
         --  we are not in a loop construct. So ignore the builtin and return 0
         Put (S.all, 2, "break: only meaningful in a " &
              "`for', `while', or `until' loop" & ASCII.LF);
         return 0;
      end if;

      if Args'Length = 0 then
         Break_Number := Current_Loop_Level;
      else
         To_Integer (Args (Args'First).all, Break_Number, Is_Valid);
         if not Is_Valid then
            Put (S.all, 2, "break: " &
                 Args (Args'First).all &
                 ":numeric argument required" & ASCII.LF);
            Shell_Exit (S.all, 128);
         end if;

         if Break_Number < 1 then
            return 1;
         end if;

         Break_Number := Current_Loop_Level - Break_Number + 1;
         if Break_Number < 1 then
            Break_Number := 1;
         end if;
      end if;

      raise Break_Exception with To_String (Break_Number);

      return 0;
   end Break_Builtin;

   -----------------
   -- Cat_Builtin --
   -----------------

   function Cat_Builtin
     (S : Shell_State_Access;
      Args : String_List)
      return Integer
   is
      Fd : File_Descriptor;
      Buffer : String_Access := null;
      R : Integer;
   begin

      --  If no argument is given to cat then we assume that stdin should be
      --  dump.
      if Args'Length = 0 then
         Put (S.all, 1, Read (S.all, 0));
         return 0;
      end if;

      Buffer := new String (1 .. 1024 *1024);

      for J in Args'Range loop
         --  '-' means that we need to dump stdin otherwise the argument is
         --  interpreted as a filename.
         if Args (J).all = "-" then
            Put (S.all, 1, Read (S.all, 0));
         else
            Fd := Open_Read (Resolve_Path (S.all, Args (J).all), Binary);
            if Fd < 0 then
               Put (S.all, 2, "cat: " & Args (J).all &
                    ": No such file or directory" & ASCII.LF);
            else
               loop
                  R := Read (Fd, Buffer.all'Address, Buffer.all'Last);
                  if R > 0 then
                     Put (S.all, 1, Strip_CR (Buffer.all (1 .. R)));
                  end if;
                  exit when R /= Buffer.all'Last;
               end loop;
               Close (Fd);
            end if;
         end if;
      end loop;

      Free (Buffer);

      return 0;
   end Cat_Builtin;

   ----------------
   -- Change_Dir --
   ----------------

   function Change_Dir
     (S        : Shell_State_Access;
      Dir_Name : String;
      Verbose  : Boolean := False)
      return Integer
   is
      function Get_Absolute_Path (D : String) return String;

      function Get_Absolute_Path (D : String) return String is
      begin
         if Is_Absolute_Path (D) then
            return D;
         else
            return Get_Current_Dir (S.all) & "/" & D;
         end if;
      end Get_Absolute_Path;

      Abs_Dir : constant String := Get_Absolute_Path (Dir_Name);

   begin
      if Dir_Name = "" then
         return 0;
      end if;


      if not Is_Directory (Abs_Dir) then
         Put (S.all, 2, "cd: " & Dir_Name & ": No such file or directory");
         New_Line (S.all, 2);
         return 1;
      end if;

      declare
         use GNAT.Directory_Operations;
         Full_Path : constant String := Format_Pathname
           (GNAT.OS_Lib.Normalize_Pathname (Abs_Dir),
            GNAT.Directory_Operations.UNIX);
      begin
         Set_Current_Dir (S.all, Full_Path);
         Set_Var_Value (S.all, "OLDPWD", Get_Var_Value (S.all, "PWD"));

         --  Update PWd variable. Use a Unix format (without drive letter)
         Set_Var_Value (S.all, "PWD", Get_Current_Dir (S.all, True));
      end;

      if Verbose then
         Put (S.all, 1, Dir_Name);
         New_Line (S.all, 1);
      end if;

      return 0;

   exception
      when GNAT.Directory_Operations.Directory_Error =>
         Put (S.all, 2,
              "cd: " & Dir_Name & ": Cannot change to this directory");
         New_Line (S.all, 2);
         return 1;
   end Change_Dir;

   ------------------------
   -- Change_Dir_Builtin --
   ------------------------

   function Change_Dir_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
   begin
      --  If there was no argument provided, then cd to the HOME directory.
      --  If HOME directory is not provided, then the behavior is
      --  implementation-defined, and we simply do nothing.
      if Args'Length =  0 then
         return Change_Dir (S, Get_Var_Value (S.all, "HOME"));
      end if;

      --  "-" is a special case: It should be equivalent to
      --  ``cd "$OLDPWD" && pwd''
      if Args (Args'First).all = "-" then
         return Change_Dir
           (S, Get_Var_Value (S.all, "OLDPWD"), Verbose => True);
      end if;

      return Change_Dir (S, Args (Args'First).all);
   end Change_Dir_Builtin;

   ----------------------
   -- Continue_Builtin --
   ----------------------

   function Continue_Builtin
     (S : Shell_State_Access;
      Args : String_List)
      return Integer
   is
      Break_Number : Integer;
      Is_Valid : Boolean;
      Current_Loop_Level : constant Natural := Get_Loop_Scope_Level (S.all);
   begin

      if Current_Loop_Level = 0 then
         --  we are not in a loop construct. So ignore the builtin and return 0
         Put (S.all, 2, "continue: only meaningful in a " &
              "`for', `while', or `until' loop" & ASCII.LF);
         return 0;
      end if;

      if Args'Length = 0 then
         Break_Number := Current_Loop_Level;
      else
         To_Integer (Args (Args'First).all, Break_Number, Is_Valid);
         if not Is_Valid then
            Put (S.all, 2, "continue: " &
                 Args (Args'First).all &
                 ":numeric argument required" & ASCII.LF);
            Shell_Exit (S.all, 128);
         end if;

         if Break_Number < 1 then
            return 1;
         end if;

         Break_Number := Current_Loop_Level - Break_Number + 1;
         if Break_Number < 1 then
            Break_Number := 1;
         end if;
      end if;

      raise Continue_Exception with To_String (Break_Number);

      return 0;
   end Continue_Builtin;

   ------------------
   -- Echo_Builtin --
   ------------------

   function Echo_Builtin
     (S : Shell_State_Access;
      Args : String_List)
      return Integer
   is
      Enable_Newline : Boolean := True;
      In_Options : Boolean := True;
   begin
      for I in Args'Range loop
         if Args (I).all /= "" then

            case Args (I).all (Args (I)'First) is
            when '-' =>
               if Args (I).all = "-n" and In_Options then
                  Enable_Newline := False;
               else
                  In_Options := False;
                  Put (S.all, 1, Args (I).all);
                  if I < Args'Last then
                     Put (S.all, 1, " ");
                  end if;
               end if;
            when others =>
               In_Options := False;
               Put (S.all, 1, Args (I).all);
               if I < Args'Last then
                  Put (S.all, 1, " ");
               end if;
            end case;
         end if;
      end loop;

      if Enable_Newline then
         New_Line (S.all, 1);
      end if;
      return 0;
   end Echo_Builtin;

   ------------------
   -- Eval_Builtin --
   ------------------

   function Eval_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      Str : Ada.Strings.Unbounded.Unbounded_String;
      T : Shell_Tree_Access := New_Tree;
      use Ada.Strings.Unbounded;
   begin
      Str := To_Unbounded_String (Args (Args'First).all);
      for I in Args'First + 1 .. Args'Last loop
         Str := Str & " " & Args (I).all;
      end loop;

      T := Parse_String (To_String (Str));
      Eval (S, T.all);
      Free_Node (T);
      return Get_Last_Exit_Status (S.all);
   exception
      when Shell_Syntax_Error =>
         return 1;
   end Eval_Builtin;

   ------------------
   -- Exec_Builtin --
   ------------------

   function Exec_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      Result : Integer;
   begin
      if Args'Length = 0 then
         return 0;
      else
         declare
            Command : constant String := Args (Args'First).all;
            Arguments : constant String_List :=
              Args (Args'First + 1 .. Args'Last);
         begin
            Result := Run (S, Command, Arguments, Get_Environment (S.all));
            Shell_Exit (S.all, Result);
         end;
      end if;
      return 0;
   end Exec_Builtin;

   ---------------------
   -- Execute_Builtin --
   ---------------------

   function Execute_Builtin
     (S    : Shell_State_Access;
      Cmd  : String;
      Args : String_List)
      return Integer
   is
      Builtin : constant Builtin_Function := Element (Builtin_Map, Cmd);
   begin
      return Builtin (S, Args);
   end Execute_Builtin;

   ------------------
   -- Exit_Builtin --
   ------------------

   function Exit_Builtin
     (S    : Shell_State_Access;
      Args : String_List)
      return Integer
   is
      Exit_Code : Integer;
      Success : Boolean;
   begin
      --  Calling "exit" without argument is equivalent to calling
      --  it with "$?" as its argument.
      if Args'Length = 0 then
         Shell_Exit (S.all, Get_Last_Exit_Status (S.all));
      end if;

      --  If more than one argument was provided, print an error
      --  message and return 1.
      if Args'Length > 1 then
         Error (S.all, "exit: too many arguments");
         return 1;
      end if;

      To_Integer (Args (Args'First).all, Exit_Code, Success);
      if not Success then
         --  The exit code value is not entirely numeric.
         --  Report the error and exit with value 255.
         Error (S.all, "exit: " & Args (Args'First).all
                & ": numeric argument required");
         Exit_Code := 255;
      end if;

      --  Exit with the code specified.
      Shell_Exit (S.all, Exit_Code);
   end Exit_Builtin;

   ------------
   -- Export --
   ------------

   function Export_Builtin
     (S : Shell_State_Access;
      Args : String_List)
      return Integer
   is
   begin
      for I in Args'Range loop
         Export_Var (S.all, Args (I).all);
      end loop;
      return 0;
   end Export_Builtin;

   -------------------
   -- False_Builtin --
   -------------------

   function False_Builtin
     (S : Shell_State_Access;
      Args : String_List)
      return Integer
   is
      pragma Unreferenced (Args);
      pragma Unreferenced (S);
   begin
      return 1;
   end False_Builtin;

   ----------------
   -- Is_Builtin --
   ----------------

   function Is_Builtin (Cmd : String) return Boolean is
   begin
      return Contains (Builtin_Map, Cmd);
   end Is_Builtin;

   -------------------
   -- Limit_Builtin --
   -------------------

   function Limit_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      pragma Unreferenced (Args);
      pragma Unreferenced (S);
   begin
      return 0;
   end Limit_Builtin;

   -----------------
   -- Pwd_Builtin --
   -----------------

   function Pwd_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      pragma Unreferenced (Args);
   begin
      Put (S.all, 1, Get_Current_Dir (S.all, True) & ASCII.LF);
      return 0;
   end Pwd_Builtin;

   ------------------
   -- Read_Builtin --
   ------------------

   function Read_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      CC : Character := Read (S.all, 0);
      Line : Annotated_String := Null_Annotated_String;
   begin
      --  First read the complete line
      while CC /= ASCII.LF and CC /= ASCII.EOT loop
         if CC /= ASCII.CR then
            Append (Line, CC, NO_ANNOTATION);
         end if;
         CC := Read (S.all, 0);
      end loop;

      if Args'Length > 0 then
         declare
            List : constant String_List := Eval_String
              (S, Line, Args'Length - 1);
            Index : Integer := List'First;
         begin

            for J in Args'Range loop
               if Index <= List'Last then
                  Set_Var_Value (S.all, Args (J).all, List (Index).all);
                  Index := Index + 1;
               else
                  Set_Var_Value (S.all, Args (J).all, "");
               end if;
            end loop;
         end;
      end if;

      if CC = ASCII.EOT then
         return 1;
      else
         return 0;
      end if;

   end Read_Builtin;

   -------------------
   -- REcho_Builtin --
   -------------------

   function REcho_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      function Replace_LF (S : String) return String;

      function Replace_LF (S : String) return String is
         Result : String (S'First .. S'Last * 2);
         Result_Index : Integer := Result'First;
      begin
         for I in S'Range loop
            if S (I) = ASCII.LF then
               Result (Result_Index) := '^';
               Result (Result_Index + 1) := 'J';
               Result_Index := Result_Index + 2;
            else
               Result (Result_Index) := S (I);
               Result_Index := Result_Index + 1;
            end if;
         end loop;
         return Result (S'First .. Result_Index - 1);
      end Replace_LF;
   begin
      for I in Args'Range loop
         Put (S.all, 1, "argv[" & To_String (I - Args'First + 1) & "] = <" &
              Replace_LF (Args (I).all) & ">");
         if I < Args'Last then
            New_Line (S.all, 1);
         end if;
      end loop;
      New_Line (S.all, 1);
      return 0;
   end REcho_Builtin;

   --------------------
   -- Return_Builtin --
   --------------------

   function Return_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      Return_Value : Integer;
      Success : Boolean;
   begin
      --  If more than one argument was provided: Report an error and
      --  execute the return with a fixed return value of 1.
      if Args'Length > 1 then
         Error (S.all, "return: too many arguments");
         Save_Last_Exit_Status (S.all, 1);

      --  If one argument was provided: Return with this value.
      elsif Args'Length = 1 then
         To_Integer (Args (Args'First).all, Return_Value, Success);
         if not Success then
            --  The provided value is not a valid number, so report
            --  this problem, and force the return value to 255.
            Error (S.all, "return: " & Args (Args'First).all
                   & ": numeric argument required");
            Return_Value := 255;
         end if;
         Save_Last_Exit_Status (S.all, Return_Value);
      end if;

      --  Note: If no argument is provided, then return using the exit
      --  status of the last command executed. This exit status has
      --  already been saved, so no need to save it again.

      --  Now perform the return.
      raise Shell_Return_Exception;

      --  Ugh! The compiler insists that a "return" should be found in
      --  the function body or the compilation will fail. The following
      --  return statement is absolutely useless, but makes the compiler
      --  happy.
      return 0;
   end Return_Builtin;

   ----------------
   -- Rm_Builtin --
   ----------------

   function Rm_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      Rm_Binary_Path : String_Access := null;
      Rm_Args : String_List (1 .. Args'Length) := (others => null);
      Rm_Last : Natural := 0;
      Have_File : Boolean := False;
   begin
      Rm_Binary_Path := Locate_Exec (S.all, "rm.exe");
      for J in Args'Range loop
         if Is_Directory (Args (J).all)
           or else Is_Regular_File (Args (J).all)
         then
            Rm_Last := Rm_Last + 1;
            Rm_Args (Rm_Last) := Args (J);
            Have_File := True;
         elsif Args (J).all'Length > 0
           and then Args (J).all (Args (J).all'First) = '-'
         then
            Rm_Last := Rm_Last + 1;
            Rm_Args (Rm_Last) := Args (J);
         end if;
      end loop;

      if Have_File then
         return Run
           (S,
            Rm_Binary_Path.all,
            Rm_Args (1 .. Rm_Last),
            Get_Environment (S.all));
      else
         return 0;
      end if;
   end Rm_Builtin;

   -----------------
   -- Set_Builtin --
   -----------------

   function Set_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      Saved_Index : Integer := -1;
   begin
      if Args'Length = 0 then
         return 0;
      end if;

      --  Parse options
      for Index in Args'Range loop
         if Args (Index)'Length > 0 then
            case Args (Index) (Args (Index)'First) is
               when '-' =>
                  if Args (Index).all = "--" then
                     Saved_Index := Index + 1;
                     exit;
                  elsif Args (Index).all = "-x" then
                     Set_Xtrace (S.all, True);
                  else
                     null;
                  end if;
               when '+' =>
                  if Args (Index).all = "+x" then
                     Set_Xtrace (S.all, False);
                  end if;

               when others => Saved_Index := Index; exit;
            end case;
         end if;
      end loop;

      if Saved_Index >= Args'First and then Saved_Index <= Args'Last then
         Set_Positional_Parameters (S.all, Args (Saved_Index .. Args'Last));
      end if;
      return 0;
   end Set_Builtin;

   -------------------
   -- Shift_Builtin --
   -------------------

   function Shift_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      Shift : Integer := 1;
      Success : Boolean;
   begin
      --  If more than one argument was provided: Report an error,
      --  and abort with error code 1.

      if Args'Length > 1 then
         Error (S.all, "shift: too many arguments");
         Shell_Exit (S.all, 1);
      end if;

      --  If one argument was provided, convert it to an integer
      --  and use it as the number of shifts to perform.

      if Args'Length = 1 then
         To_Integer (Args (Args'First).all, Shift, Success);

         if not Success then
            Error (S.all, "shift: " & Args (Args'First).all
                   & ": numeric argument required");
            Shell_Exit (S.all, 1);
         end if;

         if Shift < 0 then
            Error (S.all, "shift: " & Args (Args'First).all
                   & ": shift count out of range");
            return 1;
         end if;
      end if;

      Shift_Positional_Parameters (S.all, Shift, Success);
      if Success then
         return 0;
      else
         return 1;
      end if;
   end Shift_Builtin;

   --------------------
   -- Source_Builtin --
   --------------------

   function Source_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      T : Shell_Tree_Access;
      Return_Code : Integer;
      Saved_Pos_Params : Pos_Params_State;
   begin
      if Args'Length = 0 then
         Error (S.all, ".: filename argument required");
         return 2;
      end if;

      begin
         T := Parse_File (Args (Args'First).all);
      exception
         when Buffer_Read_Error =>
            return 1;
      end;

      --  If some arguments are provided for the script, then set
      --  these arguments up. This is an extension introduced by
      --  KornShell, and POSIX says that "this is a valid extension
      --  that allows a dot script to behave identically to a function".
      --
      --  Note: If no arguments are provided, then do NOT set the arguments
      --  up, because the script should be in this case able to access
      --  the positional arguments of the parent script.
      if Args'Length > 1 then
         Saved_Pos_Params := Get_Positional_Parameters (S.all);
         Set_Positional_Parameters
           (S.all, Args (Args'First + 1 .. Args'Last), False);
      end if;

      begin
         Eval (S, T.all);
         Return_Code := Get_Last_Exit_Status (S.all);
         Free_Node (T);
      exception
         when Shell_Return_Exception =>
            Return_Code := Get_Last_Exit_Status (S.all);
      end;

      --  Restore the positional parameters if necessary.
      if Args'Length > 1 then
         Restore_Positional_Parameters (S.all, Saved_Pos_Params);
      end if;

      return Return_Code;
   end Source_Builtin;

   ------------------
   -- True_Builtin --
   ------------------

   function True_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      pragma Unreferenced (Args);
      pragma Unreferenced (S);
   begin
      return 0;
   end True_Builtin;

   -------------------
   -- Unset_Builtin --
   -------------------

   function Unset_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
   begin
      for Index in Args'Range loop
         Unset_Var (S.all, Args (Index).all);
      end loop;
      return 0;
   end Unset_Builtin;

   ----------------------
   -- Unsetenv_Builtin --
   ----------------------

   function Unsetenv_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
   begin
      Export_Var (S.all, Args (Args'First).all, "");
      return 0;
   end Unsetenv_Builtin;

   function Wc_Builtin
     (S : Shell_State_Access; Args : String_List) return Integer
   is
      pragma Unreferenced (Args);
      Result : constant String := Read (S.all, 0);
   begin
      Put (S.all, 1, To_String (Result'Length));
      Put (S.all, 1, ASCII.LF & "");
      return 0;
   end Wc_Builtin;

begin

   --  Register all the builtins.
   Include (Builtin_Map, "pwd",           Pwd_Builtin'Access);
   Include (Builtin_Map, ".",             Source_Builtin'Access);
   Include (Builtin_Map, "cd",            Change_Dir_Builtin'Access);
   Include (Builtin_Map, "echo",          Echo_Builtin'Access);
   Include (Builtin_Map, "eval",          Eval_Builtin'Access);
   Include (Builtin_Map, "exit",          Exit_Builtin'Access);
   Include (Builtin_Map, "export",        Export_Builtin'Access);
   Include (Builtin_Map, "false",         False_Builtin'Access);
   Include (Builtin_Map, "limit",         Limit_Builtin'Access);
   Include (Builtin_Map, "recho",         REcho_Builtin'Access);
   Include (Builtin_Map, "return",        Return_Builtin'Access);
   Include (Builtin_Map, "set",           Set_Builtin'Access);
   Include (Builtin_Map, "setenv",        Export_Builtin'Access);
   Include (Builtin_Map, "shift",         Shift_Builtin'Access);
   Include (Builtin_Map, "test",          Test_Builtin'Access);
   Include (Builtin_Map, "true",          True_Builtin'Access);
   Include (Builtin_Map, "umask",         Limit_Builtin'Access);
   Include (Builtin_Map, "unsetenv",      Unsetenv_Builtin'Access);
   Include (Builtin_Map, "unset",         Unset_Builtin'Access);
   Include (Builtin_Map, "[",             Test_Builtin'Access);
   Include (Builtin_Map, "printf",        Builtin_Printf'Access);
   Include (Builtin_Map, "expr",          Builtin_Expr'Access);
   Include (Builtin_Map, "wc",            Wc_Builtin'Access);
   Include (Builtin_Map, ":",             True_Builtin'Access);
   Include (Builtin_Map, "exec",          Exec_Builtin'Access);
   Include (Builtin_Map, "continue",      Continue_Builtin'Access);
   Include (Builtin_Map, "break",         Break_Builtin'Access);
   Include (Builtin_Map, "trap",          True_Builtin'Access);
   Include (Builtin_Map, "cat",           Cat_Builtin'Access);
   Include (Builtin_Map, "read",          Read_Builtin'Access);
   Include (Builtin_Map, "rm",            Rm_Builtin'Access);
   Include (Builtin_Map, "tail",          Tail_Builtin'Access);
   Include (Builtin_Map, "head",          Head_Builtin'Access);
end Posix_Shell.Builtins;