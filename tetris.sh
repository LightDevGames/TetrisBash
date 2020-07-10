#!/bin/bash

######--------------------------------#####
######          Константы
######--------------------------------#####

USE_COLORS=1 # 1 - использовать цвета, 0 - не использовать

COLOR_BACKGROUND=0 # чёрный
COLOR_BORDER=7 # белый
COLOR_BLOCK=1 # красный

UPDATE_DELAY=0.4 # время между кадрами
BORDER_CHAR='|'
BLOCK_CHAR='*'
BLOCK_EMPTY_CHAR=' '

GAME_FIELD_WIDTH=14
GAME_FIELD_HEIGHT=14

REWARD_BLOCK=5 # награда за поставленный блок
REWARD_LINE=100 # награда за заполненную линию из блоков

TEXT_OFFSET_X=3
NOT_FOUND=100 # код возврата из функции

# массив хранит в себе строки, которые представляют блоки, которые используются в игре
# срока разбивается на части, каждая часть состоит из 4 вершин, которые представляет rootation блока
# вершина состоит из координат y,x
# самая левая вершина имеет координаты (0,0) 
BLOCKS_COUNT=7
BLOCKS=(
"00011011"                         # квадрат
"0212223210111213"                 # линия
"0001111201101120"                 # S блок
"0102101100101121"                 # Z блок
"01021121101112220111202100101112" # L блок
"01112122101112200001112102101112" # перевернутый L блок
"01111221101112210110112101101112" # T блок
)

isOutputBusy=0 # используется для многопоточности, чтобы использование переменной могло быть только в одном потоке
score=0 # счет в игре

######--------------------------------#####
######      Работа с цветами
######--------------------------------#####

# Задаёт цвет переднего плана.
# Входные параметры. 1 - цвет
function setForeground()
{
  if [ "$USE_COLORS" = "1" ]
  then
    tput setaf $1
    tput setf $1
  fi
}

# Задаёт цвет заднего плана.
# Входные параметры. 1 - цвет
function setBackground()
{
  if [ "$USE_COLORS" = "1" ]
  then
    tput setab $1
    tput setb $1
  fi
}

# Задаёт цвет переднего и заднего плана.
# Входные параметры. 1 - цвет
function setColor()
{
  if [ "$USE_COLORS" = "1" ]
  then
    setForeground $1
    setBackground $1
  fi
}

function setTextColor()
{
  tput init # устанавливает стандартный цвет
}

######--------------------------------#####
######      Работа со счётом
######--------------------------------#####

function updateScoreText()
{
  setTextColor

  tput cup 3 $(($GAME_FIELD_WIDTH + $TEXT_OFFSET_X)) # переводит курсор на позицию (y,x)
  echo "SCORE: $score"
}

# Увеличивает счёт на x
# x - входной параметр
function increaseScoreBy()
{
  score=$(($score + $1))
}

######--------------------------------#####
######       Матрица коллизий
######--------------------------------#####

# Матрица коллизий, каждый элемент которой отвечает за один символ на экране
# 0 - ничего нет
# 1 - стоит часть блока или граница

# Заполняет матрицу коллизий нулями
function clearCollisionMatrix() 
{
  local i
  for ((i=0; i<=$GAME_FIELD_HEIGHT; i++))
  do
    collisionMatrix[$i]=$(printf '0%.0s' {1..40})
  done
}

# Заполняет строку матрицы коллизий нулями, но не перезаписывает границы на 0
# Входные параметры. 1 - индекс линии
function clearCollisionMatrixLine()
{
  local i
  for ((i=1; i<=$GAME_FIELD_WIDTH; i++))
  do
    clearInCollisionMatrix $1 $i
  done
}

# Входные параметры. 1 - индекс строки, которую копировать. 2 - индекс строки куда копировать
# Копирует строку по индексу 1 в индекс 2. Очищает строку по индексу 1
function copyCollisionMatrixLineTo()
{
  local from=$1
  local to=$2

  collisionMatrix[$to]=${collisionMatrix[$from]}
}

# Заполняет 1 в матрицу коллизий по индексу (y,x)
# Входные параметры. 1 - индекс строки начиная с нуля (y), 2 - индекс вставки начиная с нуля (x)
function insertIntoCollisionMatrix() 
{
  local prev=${collisionMatrix[$1]}
  collisionMatrix[$1]="${prev:0:$2}1${prev:($2+1)}"
}

# Заполняет 0 в матрицу коллизий по индексу (y,x)
# Входные параметры. 1 - индекс строки начиная с нуля (y), 2 - индекс вставки начиная с нуля (x)
function clearInCollisionMatrix() 
{
  local prev=${collisionMatrix[$1]}
  collisionMatrix[$1]="${prev:0:$2}0${prev:($2+1)}"
}

# Заполняет матрицу коллизий 1, 
# места вставки берутся в зависимости от блока, его текущего положения, его rootation
function insertBlockIntoCollisionMatrix()
{
  local i
  local blockLength=${#BLOCKS[$currentBlockType]}
  local maxRotType=$(($blockLength / 8))
  local rotType=$(($currentRotType % $maxRotType)) 

  # проходит по ячейкам блока: 4 ячейки, каждая по 2 координаты (y,x)
  for ((i = 0; i < 8; i += 2)) 
  {
    # координаты блока, в зависиммости от его вращения и позиции
    local startY=$(($i + $rotType * 8))
    local startX=$(($i + $rotType * 8 + 1))
    local y=$(($currentPosY + ${BLOCKS[$currentBlockType]:$startY:1}))
    local x=$(($currentPosX + ${BLOCKS[$currentBlockType]:$startX:1}))

    insertIntoCollisionMatrix $y $x
  }
}

# Возвращает 1, если в матрице коллизий по (y,x) находится 1
# Входные параметры: 1 - индекс строки (y), 2 - индекс столбца (x)
function collisionMatrixContains()
{
  local checkSymbol=${collisionMatrix[$1]:$2:1}
  return $checkSymbol;
}

# Заполнена ли строка в матрице коллизий 0 от левой границы до правой
# Входные параметры: 1 - индекс строки 
function isCollisionMatrixLineEmpty()
{
  local i
  local isEmpty="1"
  for ((i=1; i <= $GAME_FIELD_WIDTH; i++))
  do
    collisionMatrixContains $1 $i
    if [ "$?" == "1" ]
    then
      isEmpty="0"
      break
    fi
  done

  return $isEmpty
}

# Заполнена ли строка в матрице коллизий 1 от левой границы до правой
# Входные параметры: 1 - индекс строки 
function isCollisionMatrixLineFilled()
{
  local i
  local isFilled="1"
  for ((i=1; i <= $GAME_FIELD_WIDTH; i++))
  do
    collisionMatrixContains $1 $i
    if [ "$?" == "0" ]
    then
      isFilled="0"
      break
    fi
  done

  return $isFilled
}

# Находит индекс строки, которая находится под входный строкой.
# Строка, которую надо найти, заполнена нулями от левой границы до правой.
# Входные параметры: 1 - индекс строки
function getCollisionMatrixUnderLineEmptyLine()
{
  local emptyLineIndex=$NOT_FOUND
  local i
  for ((i=$(($1 + 1)); i<$GAME_FIELD_HEIGHT; i++))
  do
    isCollisionMatrixLineEmpty $i
    if [ "$?" == "1" ]
    then
      emptyLineIndex=$i
    else
      break
    fi
  done

  return $emptyLineIndex
}

######--------------------------------#####
######          Границы
######--------------------------------#####

function printBordersAndFillCollisionMatrix()
{
  local i
  local maxX=$(($GAME_FIELD_WIDTH + 1))

  # отрисовываем задний фон
  setColor $COLOR_BACKGROUND
  for ((i = 0; i<$GAME_FIELD_HEIGHT; i++))
  do
	printf '%*s\n' "$(($GAME_FIELD_WIDTH + 1))" | tr ' ' "$BLOCK_EMPTY_CHAR"
  done

  # отрисовываем левую и правую границу и вставляем их в матрицу коллизий
  setColor $COLOR_BORDER
  for ((i=0; i < $GAME_FIELD_HEIGHT; i++))
  do
    insertIntoCollisionMatrix $i 0
    tput cup $i 0
    echo "$BORDER_CHAR"

    insertIntoCollisionMatrix $i $maxX
    tput cup $i $maxX
    echo "$BORDER_CHAR"
  done

  # отрисовываем нижнюю границу и вставляем их в матрицу коллизий
  for ((i=0; i <= $maxX; i++))
  do
    insertIntoCollisionMatrix $GAME_FIELD_HEIGHT $i
    tput cup $GAME_FIELD_HEIGHT $i
    echo "$BORDER_CHAR"
  done
}

######--------------------------------#####
######   Визуальная работа с блоком
######--------------------------------#####

# Отрисовывает блок в зависиммости от текущего типа, позиции и rotation
# Входные параметры: 1 - символ для отрисовки
function printBlockUtil()
{
  local i
  local blockLength=${#BLOCKS[$currentBlockType]}
  local maxRotType=$(($blockLength / 8))
  local rotType=$(($currentRotType % $maxRotType)) 

  for ((i = 0; i < 8; i += 2)) 
  {
    local startX=$(($i + $rotType * 8 + 1))
    local startY=$(($i + $rotType * 8))
    local x=$(($currentPosX + ${BLOCKS[$currentBlockType]:$startX:1}))
    local y=$(($currentPosY + ${BLOCKS[$currentBlockType]:$startY:1}))

    tput cup $y $x
    echo "$1"
  }
}

# Отрисовывает блок
function printBlock()
{
  setColor $COLOR_BLOCK
  printBlockUtil "$BLOCK_CHAR"
}

# Убирает блок с экрана
function clearBlock()
{
  setColor $COLOR_BACKGROUND
  printBlockUtil "$BLOCK_EMPTY_CHAR"
}

# Очищает линию из блоков
# Входные параметры: 1 - индекс линии для очистки
function clearBlockLine()
{
  setColor $COLOR_BACKGROUND

  local i
  for ((i=1; i<=$GAME_FIELD_WIDTH; i++))
  do
    tput cup $1 $i
    echo "$BLOCK_EMPTY_CHAR"
  done
}

# Перерисовывает строку в соответсвии матрицы коллизий
# Входные параметры: 1 - индекс строки для перерисовки
function redrawBlockLine()
{
  clearBlockLine $1

  setColor $COLOR_BLOCK
  local i
  for ((i=1; i<=$GAME_FIELD_WIDTH; i++))
  do
    collisionMatrixContains $1 $i
    if [ "$?" == "1" ]
    then
      tput cup $1 $i
      echo "$BLOCK_CHAR"
    fi
  done
}

######--------------------------------#####
######     Манипуляции с блоком
######--------------------------------#####

function resetBlockValues()
{
  currentPosX=1
  currentPosY=0
  currentRotType=$(($RANDOM % 4))
  currentBlockType=$(($RANDOM % $BLOCKS_COUNT))
}

# Если текущий блок может занять позицию после вращения
#   вращает и перерисовывает его
function rotateBlock()
{
  currentRotType=$(($currentRotType + 1))
  canBlockMoveToPosition $currentPosY $currentPosX
  if [ $? == "1" ]
  then
    currentRotType=$(($currentRotType - 1))
    clearBlock
    currentRotType=$(($currentRotType + 1))
    printBlock
  else
    currentRotType=$(($currentRotType - 1))
  fi
}

# Если текущий блок может занять позицию после перемещения
#   перемещает и перерисовывает его
function moveBlockLeft()
{
  canBlockMoveToPosition $currentPosY $(($currentPosX - 1))
  if [ $? == "1" ]
  then
    clearBlock
    currentPosX=$(($currentPosX - 1))
    printBlock
  fi
}

# Если текущий блок может занять позицию после перемещения
#   перемещает и перерисовывает его
function moveBlockRight()
{
  canBlockMoveToPosition $currentPosY $(($currentPosX + 1))
  if [ $? == "1" ]
  then
    clearBlock
    currentPosX=$(($currentPosX + 1))
    printBlock
  fi
}

# Может ли текущий блок, занять позицию (y,x) в соответствие с матрицей коллизий
# Входные параметры: 1 - индекс строки (y), 2 - индекс столбца (x)
function canBlockMoveToPosition()
{
  local i
  local blockLength=${#BLOCKS[$currentBlockType]}
  local maxRotType=$(($blockLength / 8))
  local rotType=$(($currentRotType % $maxRotType)) 

  for ((i = 0; i < 8; i += 2)) 
  {
    local startY=$(($i + $rotType * 8))
    local startX=$(($i + $rotType * 8 + 1))
    local y=$(($1 + ${BLOCKS[$currentBlockType]:$startY:1}))
    local x=$(($2 + ${BLOCKS[$currentBlockType]:$startX:1}))

    collisionMatrixContains $y $x
    if [ $? == "1" ]
    then
      return 0
    fi
  }

  return 1
}

######--------------------------------#####
######       Game Life Cycle
######--------------------------------#####

# Начальный экран
function showSpalshScreen()
{
  clear

  echo ""
  echo ""
  echo "         Lab 1"
  echo "  Made by Bilenko Yehor"
  echo "       PZPI-18-4"
  echo ""
  echo ""
  echo "   Use:"
  echo "  A - move left"
  echo "  D - move right"
  echo "  R - rotate"
  echo "  Q - quit"
  echo ""
  echo " USE ONLY ENGLISH KEYS!"
  echo ""
  echo "    Press any key..."

  read -n 1 a
  runGame
}

# Инициализирует вывод
# Заполняет матрицу коллизий
# Отрисовывает границы
function init()
{
  clear
  tput civis # прячет курсор
  stty -echo # прячет то, что выводится в консоль, при нажатии на клавишу

  resetBlockValues

  clearCollisionMatrix
  printBordersAndFillCollisionMatrix

  updateScoreText
}

# Каждый кадр с задержкой
function update() 
{
  ( sleep $UPDATE_DELAY && kill -ALRM $$ ) & # задержка, проверка существования процесса, и запуск нового 

  if [ "$isOutputBusy" == "0" ] # не производим никаких дейсвий, если в данный момент блок может вращаться или перемещаться
  then
    isOutputBusy=1
    canBlockMoveToPosition $(($currentPosY + 1)) $currentPosX
    if [ $? == "1" ]  # может двигаться вниз
    then
      clearBlock
      currentPosY=$(($currentPosY + 1))
    else              # не может двигаться вниз
      insertBlockIntoCollisionMatrix
      increaseScoreBy $REWARD_BLOCK
  
      # Находим строки, которые полностью заполнены блоками
      local i j filledLines filledIndex
      filledIndex=0
      for ((i=0; i < $GAME_FIELD_HEIGHT; i++))
      do
        isCollisionMatrixLineFilled $i
        if [ "$?" == "1" ]
        then
          filledLines[$filledIndex]=$i
          filledIndex=$(($filledIndex + 1))
          increaseScoreBy $REWARD_LINE
          updateScoreText
        fi
      done

      # Есть заполненные строки
      if [ "$filledIndex" -ne "0" ]
      then
        # Чистим строки в матрицы коллизий
        for ((i=0; i < $filledIndex; i++))
        do
          clearCollisionMatrixLine ${filledLines[$i]}
        done

        # Двигаем строки в матрице коллизий и визуально двигаем блоки вниз
        for ((i=$(($GAME_FIELD_HEIGHT - 2)); i >= 0; i--))
        do
          getCollisionMatrixUnderLineEmptyLine $i

          local emptyLineIndex=$?
          if [ "$emptyLineIndex" -ne "$NOT_FOUND" ]
          then
            copyCollisionMatrixLineTo $i $emptyLineIndex
            clearCollisionMatrixLine $i
            clearBlockLine $i
            redrawBlockLine $emptyLineIndex
          fi
        done
      fi

      # проверка на то, можем ли генерить новый блок, если нет, то GameOver
      isCollisionMatrixLineEmpty 0
      if [ "$?" == "0" ]
      then
        gameOver
        return
      fi

      # Генерим новый блок
      resetBlockValues
      updateScoreText
    fi

    printBlock
    isOutputBusy=0
  fi
}

function runUpdate()
{
  trap update ALRM
  update
}

function readInput()
{
  while :
  do
    read -n 1 key
    case "$key" in
    a)
      if [ "$isOutputBusy" == "0" ]
      then
        isOutputBusy=1
        moveBlockLeft
        isOutputBusy=0
      fi;;
    d)
      if [ "$isOutputBusy" == "0" ]
      then
        isOutputBusy=1
        moveBlockRight
        isOutputBusy=0
      fi;;
    r)
      if [ "$isOutputBusy" == "0" ]
        then
        isOutputBusy=1
        rotateBlock
        isOutputBusy=0
      fi;;
    q)    
      gameOver;;
    esac
  done
}

function gameOver()
{
  trap exit ALRM

  tput init # возвращает цвет
  tput cup 6 $(($GAME_FIELD_WIDTH + $TEXT_OFFSET_X))
  echo "GAME OVER!"
  tput cup $(($GAME_FIELD_HEIGHT + 1)) 0
  tput cvvis # показывает курсор
  stty echo # перестаёт прятать то, что выводится в консоль при вводе
  tput init # возвращает цвет
}

function runGame()
{
  init
  runUpdate
  readInput
}

showSpalshScreen
